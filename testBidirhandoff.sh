clear; echo "Bidirhandoff"; (trap 'kill 0' SIGINT; stack run ldgv -- interpret < networking-examples/bidirhandoff/server.ldgvnw & stack run ldgv -- interpret < networking-examples/bidirhandoff/serverhandoff.ldgvnw & stack run ldgv -- interpret < networking-examples/bidirhandoff/clienthandoff.ldgvnw & stack run ldgv -- interpret < networking-examples/bidirhandoff/client.ldgvnw & wait); 
exit;