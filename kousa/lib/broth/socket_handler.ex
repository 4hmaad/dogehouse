defmodule Broth.SocketHandler do
  require Logger

  alias Beef.Users
  alias Beef.Rooms
  alias Beef.Follows
  alias Ecto.UUID
  alias Beef.RoomPermissions

  @type state :: %__MODULE__{
          awaiting_init: boolean(),
          user_id: String.t(),
          encoding: :etf | :json,
          compression: nil | :zlib
        }

  defstruct awaiting_init: true,
            user_id: nil,
            encoding: nil,
            compression: nil,
            callers: []

  @behaviour :cowboy_websocket

  def init(request, _state) do
    props = :cowboy_req.parse_qs(request)

    compression =
      case :proplists.get_value("compression", props) do
        p when p in ["zlib_json", "zlib"] -> :zlib
        _ -> nil
      end

    encoding =
      case :proplists.get_value("encoding", props) do
        "etf" -> :etf
        _ -> :json
      end

    state = %__MODULE__{
      awaiting_init: true,
      user_id: nil,
      encoding: encoding,
      compression: compression,
      callers: get_callers(request)
    }

    {:cowboy_websocket, request, state}
  end

  if Mix.env() == :test do
    defp get_callers(request) do
      request_bin = :cowboy_req.header("user-agent", request)

      List.wrap(
        if is_binary(request_bin) do
          request_bin
          |> Base.decode16!()
          |> :erlang.binary_to_term()
        end
      )
    end
  else
    defp get_callers(_), do: []
  end

  @auth_timeout Application.compile_env(:kousa, :websocket_auth_timeout)

  def websocket_init(state) do
    Process.send_after(self(), :auth_timeout, @auth_timeout)
    Process.put(:"$callers", state.callers)

    {:ok, state}
  end

  def websocket_info(:auth_timeout, state) do
    if state.awaiting_init do
      {:stop, state}
    else
      {:ok, state}
    end
  end

  def websocket_info({:remote_send, message}, state) do
    {:reply, prepare_socket_msg(message, state), state}
  end

  # @todo when we swap this to new design change this to 1000
  def websocket_info({:kill}, state) do
    {:reply, {:close, 4003, "killed_by_server"}, state}
  end

  # needed for Task.async not to crash things
  def websocket_info({:EXIT, _, _}, state) do
    {:ok, state}
  end

  def websocket_info({:send_to_linked_session, message}, state) do
    send(state.linked_session, message)
    {:ok, state}
  end

  def websocket_handle({:text, "ping"}, state) do
    {:reply, prepare_socket_msg("pong", state), state}
  end

  def websocket_handle({:ping, _}, state) do
    {:reply, prepare_socket_msg("pong", state), state}
  end

  @special_cases ~w(
    block_user_and_from_room
    fetch_follow_list
    join_room_and_get_info
    audio_autoplay_error
  )

  def websocket_handle({:text, command_json}, state) do
    with {:ok, message_map!} <- Jason.decode(command_json),
         # temporary trap mediasoup direct commands
         %{"op" => <<not_at>> <> _} when not_at != ?@ <- message_map!,
         # temporarily trap special cased commands
         %{"op" => not_special_case} when not_special_case not in @special_cases <- message_map!,
         # translation from legacy maps to new maps
         message_map! = Broth.Translator.convert_inbound(message_map!),
         {:ok, message = %{errors: nil}} <- validate(message_map!, state) do
      dispatch(message, state)
    else
      # special cases: mediasoup operations
      _mediasoup_op = %{"op" => "@" <> _} ->
        raise "foo"

      # legacy special cases
      msg = %{"op" => special_case} when special_case in @special_cases ->
        Broth.LegacyHandler.process(msg, state)

      {:error, %Jason.DecodeError{}} ->
        {:reply, {:close, 4001, "invalid input"}, state}

      # error validating the inner changeset.
      {:ok, error} ->
        {:reply, prepare_socket_msg(error, state), state}

      {:error, changeset = %Ecto.Changeset{}} ->
        reply = %{errors: Kousa.Utils.Errors.changeset_errors(changeset)}
        {:reply, prepare_socket_msg(reply, state), state}
    end
  end

  import Ecto.Changeset

  def validate(message, state) do
    message
    |> Broth.Message.changeset(state)
    |> apply_action(:validate)
  end

  def dispatch(message, state) do
    case message.operator.execute(message.payload, state) do
      close = {:close, _, _} ->
        {:reply, close, state}

      {:error, changeset = %Ecto.Changeset{}} ->
        # hacky, we need to build a reverse lookup for the modules/operations.
        reply =
          message
          |> Map.merge(%{
            operator: message.inbound_operator,
            errors: Kousa.Utils.Errors.changeset_errors(changeset)
          })
          |> prepare_socket_msg(state)

        {:reply, reply, state}

      {:error, err} when is_binary(err) ->
        reply =
          message
          |> wrap_error(%{message: err})
          |> prepare_socket_msg(state)

        {:reply, reply, state}

      {:error, err} ->
        reply =
          message
          |> wrap_error(%{message: inspect(err)})
          |> prepare_socket_msg(state)

        {:reply, reply, state}

      {:error, errors, new_state} ->
        reply =
          message
          |> wrap_error(errors)
          |> prepare_socket_msg(new_state)

        {:reply, reply, new_state}

      {:noreply, new_state} ->
        {:ok, new_state}

      {:reply, payload, new_state} ->
        reply =
          message
          |> wrap(payload)
          |> prepare_socket_msg(new_state)

        {:reply, reply, new_state}
    end
  end

  def wrap(message, payload = %module{}) do
    %{message | operator: message.inbound_operator <> ":reply", payload: payload}
  end

  def wrap_error(message, error_map) do
    %{message | payload: %{}, errors: error_map}
  end

  def handler("make_room_public", %{"newName" => new_name}, state) do
    Kousa.Room.make_room_public(state.user_id, new_name)
    {:ok, state}
  end

  def handler("set_auto_speaker", %{"value" => value}, state) do
    Kousa.Room.set_auto_speaker(state.user_id, value)

    {:ok, state}
  end

  def handler("speaking_change", %{"value" => value}, state) do
    if current_room_id = Beef.Users.get_current_room_id(state.user_id) do
      Onion.RoomSession.speaking_change(current_room_id, state.user_id, value)
    end

    {:ok, state}
  end

  # def handler("delete_account", _data, state) do
  #   Kousa.User.delete(state.user_id)
  #   # this will log the user out
  #   {:reply, {:close, 4001, "invalid_authentication"}, state}
  # end

  def handler(
        "delete_room_chat_message",
        %{"messageId" => message_id, "userId" => user_id},
        state
      ) do
    Kousa.RoomChat.delete_message(state.user_id, message_id, user_id)
    {:ok, state}
  end

  def handler("follow", %{"userId" => userId, "value" => value}, state) do
    Kousa.Follow.follow(state.user_id, userId, value)
    {:ok, state}
  end

  def handler(op, data, state) do
    with {:ok, room_id} <- Beef.Users.tuple_get_current_room_id(state.user_id) do
      voice_server_id = Onion.RoomSession.get(room_id, :voice_server_id)

      d =
        if String.first(op) == "@" do
          Map.merge(data, %{
            peerId: state.user_id,
            roomId: room_id
          })
        else
          data
        end

      Onion.VoiceRabbit.send(voice_server_id, %{
        op: op,
        d: d,
        uid: state.user_id
      })

      {:ok, state}
    else
      x ->
        IO.puts("you should never see this general rabbbitmq handler in socker_handler")
        IO.inspect(x)

        {:reply,
         prepare_socket_msg(
           %{
             op: "error",
             d: "you should never see this, if you do, try refreshing"
           },
           state
         ), state}
    end
  end

  def f_handler(
        "get_follow_list",
        %{"username" => username, "isFollowing" => get_following_list, "cursor" => cursor},
        state
      ) do
    {users, nextCursor} =
      Kousa.Follow.get_follow_list_by_username(
        state.user_id,
        username,
        get_following_list,
        cursor
      )

    %{
      users: users,
      nextCursor: nextCursor
    }
  end

  def f_handler("follow", %{"userId" => userId, "value" => value}, state) do
    Kousa.Follow.follow(state.user_id, userId, value)
    %{}
  end

  def f_handler("mute", %{"value" => value}, state) do
    Onion.UserSession.set_mute(state.user_id, value)
    %{}
  end

  @spec f_handler(<<_::64, _::_*8>>, any, atom | map) :: any
  def f_handler("get_my_scheduled_rooms_about_to_start", _data, state) do
    %{scheduledRooms: Kousa.ScheduledRoom.get_my_scheduled_rooms_about_to_start(state.user_id)}
  end

  def f_handler(
        "edit_room",
        %{"name" => name, "description" => description, "privacy" => privacy},
        state
      ) do
    case Kousa.Room.edit_room(state.user_id, name, description, privacy == "private") do
      {:error, message} ->
        %{
          error: message
        }

      _ ->
        true
    end
  end

  def f_handler("get_scheduled_rooms", data, state) do
    {scheduled_rooms, nextCursor} =
      Kousa.ScheduledRoom.get_scheduled_rooms(
        state.user_id,
        Map.get(data, "getOnlyMyScheduledRooms") == true,
        Map.get(data, "cursor")
      )

    %{
      scheduledRooms: scheduled_rooms,
      nextCursor: nextCursor
    }
  end

  def f_handler("edit_scheduled_room", %{"id" => id, "data" => data}, state) do
    case Kousa.ScheduledRoom.edit(
           state.user_id,
           id,
           data
         ) do
      :ok ->
        %{}

      {:error, msg} ->
        %{error: msg}
    end
  end

  def f_handler("delete_scheduled_room", %{"id" => id}, state) do
    Kousa.ScheduledRoom.delete(
      state.user_id,
      id
    )

    %{}
  end

  def f_handler(
        "create_room_from_scheduled_room",
        %{
          "id" => scheduled_room_id,
          "name" => name,
          "description" => description
        },
        state
      ) do
    case Kousa.ScheduledRoom.create_room_from_scheduled_room(
           state.user_id,
           scheduled_room_id,
           name,
           description
         ) do
      {:ok, d} ->
        d

      {:error, d} ->
        %{
          error: d
        }
    end
  end

  def f_handler("schedule_room", data, state) do
    case Kousa.ScheduledRoom.schedule(state.user_id, data) do
      {:ok, scheduledRoom} ->
        %{scheduledRoom: scheduledRoom}

      {:error, msg} ->
        %{error: msg}
    end
  end

  def f_handler("unban_from_room", %{"userId" => user_id}, state) do
    Kousa.RoomBlock.unban(state.user_id, user_id)
    %{}
  end

  def f_handler("get_blocked_from_room_users", %{"offset" => offset}, state) do
    case Kousa.RoomBlock.get_blocked_users(state.user_id, offset) do
      {users, nextCursor} ->
        %{users: users, nextCursor: nextCursor}

      _ ->
        %{users: [], nextCursor: nil}
    end
  end

  def f_handler("get_user_profile", %{"userId" => id_or_username}, state) do
    case UUID.cast(id_or_username) do
      {:ok, uuid} ->
        Beef.Users.get_by_id_with_follow_info(state.user_id, uuid)

      _ ->
        Beef.Users.get_by_username_with_follow_info(state.user_id, id_or_username)
    end
  end

  def prepare_socket_msg(data, state) do
    data
    |> encode_data(state)
    |> prepare_data(state)
  end

  defp encode_data(data, %{encoding: :etf}) do
    data
    |> Map.from_struct()
    |> :erlang.term_to_binary()
  end

  defp encode_data(data, %{encoding: :json}) do
    Jason.encode!(data)
  end

  defp prepare_data(data, %{compression: :zlib}) do
    z = :zlib.open()

    :zlib.deflateInit(z)
    data = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)

    {:binary, data}
  end

  defp prepare_data(data, %{encoding: :etf}) do
    {:binary, data}
  end

  defp prepare_data(data, %{encoding: :json}) do
    {:text, data}
  end
end
