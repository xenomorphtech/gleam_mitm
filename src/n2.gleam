import gleam/dynamic.{type Dynamic}
import gleam/erlang/charlist.{to_string}
import gleam/erlang/process
import gleam/int
import gleam/io

import gleam/list
import gleam/result
import gleam/string
import glisten/socket
import glisten/socket/options
import glisten/tcp
import mitm

pub type Connection {
  Connection(socket: socket.Socket, peer_name: String)
}

pub type SocketMessage {
  ClientToServer(socket.Socket, BitArray)
  ServerToClient(socket.Socket, BitArray)
  SocketClosed(socket.Socket)
  SocketError(socket.Socket, Dynamic)
}

pub fn main() {
  let args = ["9000"]
  let assert [listen_port, ..] = args
  let listen_port =
    int.parse(listen_port)
    |> result.unwrap(8080)

  io.println("Starting MITM server on port " <> int.to_string(listen_port))

  let listen_options = [options.ActiveMode(options.Passive)]

  let assert Ok(listener) = tcp.listen(listen_port, listen_options)
  accept_loop(listener)
}

fn accept_loop(listener: socket.ListenSocket) {
  case tcp.accept(listener) {
    Ok(socket) -> {
      let assert Ok(peer_name) = tcp.peername(socket)

      io.println("New connection from " <> string.inspect(peer_name) <> " to ")
      let #(target_host, target_port) =
        get_original_destination(unsafe(socket), "")
      io.println(string.inspect(#(target_host, target_port)))
      let p =
        process.start(
          fn() {
            handle_connection(
              Connection(socket: socket, peer_name: string.inspect(peer_name)),
              target_host,
              target_port,
            )
          },
          linked: False,
        )
      let _ = controlling_process(socket, p)
      accept_loop(listener)
    }
    Error(reason) -> {
      io.println("Error accepting connection: " <> error_to_string(reason))
      accept_loop(listener)
    }
  }
}

fn handle_connection(client: Connection, target_host: String, target_port: Int) {
  case connect_to_server(target_host, target_port) {
    Ok(server_socket) -> {
      io.println("Connected to target server ")

      // Start the active mode communication
      let _ = controlling_process(client.socket, process.self())

      // Set both sockets to active mode
      let assert Ok(_) =
        tcp.set_opts(client.socket, [options.ActiveMode(options.Active)])
      let assert Ok(_) =
        tcp.set_opts(server_socket, [options.ActiveMode(options.Active)])

      let state =
        mitm.MitmState(server_socket: server_socket, client_socket: client.socket)
      active_mode_communication(state)
    }
    Error(reason) -> {
      io.println(
        "Error connecting to target server: " <> error_to_string(reason),
      )
      tcp.close(client.socket)
    }
  }
}

@external(erlang, "gleam_stdlib", "identity")
@external(javascript, "../gleam_stdlib.mjs", "identity")
pub fn unsafe(a: a) -> b

fn active_mode_communication(state: mitm.MitmState) {
  let sel =
    process.selecting_anything(process.new_selector(), fn(a) -> M {
      // io.println(string.inspect(a))
      unsafe(a)
    })
  let r = process.select(sel, 600_000)
  // io.println(string.inspect(r))
  case r {
    Ok(Tcp(socket, data)) -> {
      let state = mitm.handle_data(socket, data, state)
      active_mode_communication(state)
    }

    Ok(TcpClosed(socket)) -> {
      io.println("Socket closed: " <> string.inspect(socket))
      let _ = tcp.close(state.client_socket)
      let _ = tcp.close(state.server_socket)
    }
    Error(Nil) -> {
      active_mode_communication(state)
    }
    Error(error) -> {
      io.println("Socket error: " <> " - " <> error_to_string(error))
      let _ = tcp.close(state.client_socket)
      let _ = tcp.close(state.server_socket)
    }
    other -> {
      io.println("Unexpected message received: " <> string.inspect(other))
      active_mode_communication(state)
    }
  }
}


fn error_to_string(reason) -> String {
  // Implement error to string conversion
  "Error" <> string.inspect(reason)
}

@external(erlang, "gen_tcp", "connect")
fn gen_tcp_connect(
  host: charlist.Charlist,
  port: Int,
  options: List(dynamic.Dynamic),
) -> Result(socket.Socket, dynamic.Dynamic)

fn connect_to_server(host: String, port: Int) -> Result(socket.Socket, String) {
  // Implement connection to the target server
  // This is a placeholder and needs to be implemented

  gen_tcp_connect(host |> charlist.from_string(), port, [
    dynamic.from(#(dynamic.from(Active), dynamic.from(False))),
  ])
  |> result.map_error(fn(a) { error_to_string(a) })
}

import gleam/erlang/atom

@external(erlang, "glisten_tcp_ffi", "controlling_process")
pub fn controlling_process(
  socket: socket.Socket,
  pid: process.Pid,
) -> Result(Nil, atom.Atom)

pub type M {
  Active
  Tcp(socket.Socket, BitArray)
  TcpClosed(socket.Socket)
  Raw
}

@external(erlang, "inet", "getopts")
pub fn get_raw_opts(
  socket: process.Pid,
  opts: List(dynamic.Dynamic),
) -> Result(List(BitArray), Nil)

@external(erlang, "inet", "ntoa")
pub fn inet_ntoa(ip: #(Int, Int, Int, Int)) -> charlist.Charlist

pub fn get_original_destination(
  client_socket: process.Pid,
  source: String,
) -> #(String, Int) {
  io.println(string.inspect(client_socket))
  // :inet.getopts(clientSocket, [{:raw, 0, 80, 16}])

  let opts = [unsafe(#(unsafe(Raw), 0, 80, 16))]
  io.println(string.inspect(opts))
  case unsafe(get_raw_opts(client_socket, opts)) {
    Ok([#(_, 0, 80, info)]) -> {
      let assert <<_:16, dest_port:16-big, a:8, b:8, c:8, d:8, _:bytes>> = info
      let dest_addr = #(a, b, c, d)
      let dest_addr_str =
        dest_addr
        |> inet_ntoa()
        |> to_string()
      #(dest_addr_str, dest_port)
    }
    Ok([]) -> {
      //maybe macos

      let res =
        erlang_os_cmd("sudo /sbin/pfctl -s state")
        |> charlist.to_string()
      let filtered =
        res
        |> string.split("\n")
        |> list.filter(fn(x) { string.contains(x, source) })

      case filtered {
        [f, ..] -> {
          let assert [_, b, _] = string.split(f, " <- ")
          let assert [address, port] = string.split(b, ":")
          let port_int =
            int.parse(port)
            |> result.unwrap(0)
          #(address, port_int)
        }
        [] -> panic
        // ("No matching connection found")
      }
    }
    Error(err) -> {
      //string.concat(["Error: ", to_string(err)])
      io.println(string.inspect(err))
      panic
    }
    _ -> panic
  }
}

@external(erlang, "os", "cmd")
pub fn erlang_os_cmd(command: String) -> charlist.Charlist
