import glisten/socket
import gleam/bytes_builder
import glisten/tcp

pub type MitmState {
  MitmState(server_socket: socket.Socket, client_socket: socket.Socket)
}

pub fn handle_data(socket: socket.Socket, data: BitArray, state: MitmState) {
  let _r = case socket == state.server_socket {
    True -> {
      tcp.send(state.client_socket, data |> bytes_builder.from_bit_array())
    }
    False -> {
      tcp.send(state.server_socket, data |> bytes_builder.from_bit_array())
    }
  }

  state
}
