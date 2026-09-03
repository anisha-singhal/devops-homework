import com.sun.net.httpserver.HttpServer;

import java.io.OutputStream;
import java.net.InetSocketAddress;

public class Main {

    private static final String PAGE = """
            <!doctype html>
            <html>
              <head><title>Java on Docker</title></head>
              <body style="font-family: system-ui; text-align: center; padding-top: 4rem">
                <h1>Hello World from Java!</h1>
                <p>Served by a Java container</p>
              </body>
            </html>""";

    public static void main(String[] args) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);

        server.createContext("/", exchange -> {
            byte[] body = PAGE.getBytes();
            exchange.getResponseHeaders().set("Content-Type", "text/html");
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(body);
            }
        });

        server.start();
        System.out.println("java app listening on 8080");
    }
}
