import socket

def start_tcp_server(host="192.168.100.128", port=5000):
    try:
        # Create a TCP socket
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

        # Bind the socket to the specified host and port
        server_socket.bind((host, port))
        print(f"Server started at {host}:{port}")

        # Start listening for connections (5 simultaneous connections allowed)
        server_socket.listen(5)
        print("Waiting for a connection...")

        while True:
            # Accept a new connection
            client_socket, client_address = server_socket.accept()
            print(f"Connection established with {client_address}")

            # Send a message to the client upon connection
            initial_message = "Welcome to the server!"
            client_socket.sendall(initial_message.encode("utf-8"))
            print(f"Sent initial message to {client_address}")

            while True:
                try:
                    # Receive data from the client
                    data = client_socket.recv(1024)
                    if not data:
                        print(f"Connection closed by {client_address}")
                        break

                    # Decode and print the received data
                    message = data.decode("utf-8")
                    print(f"Received: {message}")

                    # If the message starts with 'q' or 'Q', close the connection
                    if message.startswith("q") or message.startswith("Q"):
                        print(f"'q' or 'Q' received, closing connection with {client_address}")
                        client_socket.close()
                        break

                    # Send a response back to the client
                    response = "Message received."
                    client_socket.sendall(response.encode("utf-8"))

                except Exception as e:
                    print(f"Error: {e}")
                    client_socket.close()
                    break

    except KeyboardInterrupt:
        print("\nServer shutting down...")
    except Exception as e:
        print(f"Error: {e}")
    finally:
        server_socket.close()

if __name__ == "__main__":
    start_tcp_server()
