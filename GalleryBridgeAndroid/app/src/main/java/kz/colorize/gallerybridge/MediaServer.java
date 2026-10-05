package kz.colorize.gallerybridge;

import android.content.*;
import android.database.Cursor;
import android.graphics.*;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Size;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class MediaServer extends Thread {
    private final Context context;
    private final int port;
    private volatile boolean running = true;
    private ServerSocket serverSocket;

    public MediaServer(Context context, int port) {
        this.context = context.getApplicationContext();
        this.port = port;
        setName("ColorizeMediaServer");
    }

    @Override public void run() {
        try {
            serverSocket = new ServerSocket();
            serverSocket.setReuseAddress(true);
            serverSocket.bind(new InetSocketAddress("0.0.0.0", port));
            while (running) {
                Socket socket = serverSocket.accept();
                new Thread(() -> handle(socket), "ColorizeMediaClient").start();
            }
        } catch (IOException ignored) {}
    }

    public void shutdown() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (IOException ignored) {}
    }

    private void handle(Socket socket) {
        try (Socket s = socket) {
            s.setSoTimeout(30000);
            InputStream in = new BufferedInputStream(s.getInputStream());
            OutputStream out = new BufferedOutputStream(s.getOutputStream());

            String requestLine = readLine(in);
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0];
            String target = parts[1];

            Map<String,String> headers = new HashMap<>();
            String line;
            while ((line = readLine(in)) != null && !line.isEmpty()) {
                int idx = line.indexOf(':');
                if (idx > 0) headers.put(line.substring(0, idx).trim().toLowerCase(Locale.US), line.substring(idx + 1).trim());
            }

            Uri request = Uri.parse("http://localhost" + target);
            String token = request.getQueryParameter("token");
            if (token == null) token = headers.get("x-colorize-token");
            if (!validToken(token)) {
                sendText(out, 401, "application/json", "{\"error\":\"unauthorized\"}");
                return;
            }

            String path = request.getPath();
            if ("GET".equals(method) && "/api/status".equals(path)) {
                JSONObject o = new JSONObject();
                o.put("ok", true);
                o.put("device", Build.MODEL);
                o.put("android", Build.VERSION.RELEASE);
                o.put("port", port);
                sendText(out, 200, "application/json; charset=utf-8", o.toString());
            } else if ("GET".equals(method) && "/api/media".equals(path)) {
                sendMediaList(out, request);
            } else if ("GET".equals(method) && "/api/thumb".equals(path)) {
                sendThumbnail(out, parseLong(request.getQueryParameter("id"), -1));
            } else if ("GET".equals(method) && "/api/file".equals(path)) {
                sendFile(out, parseLong(request.getQueryParameter("id"), -1));
            } else if ("POST".equals(method) && "/api/upload".equals(path)) {
                receiveUpload(out, in,
                        parseLong(headers.get("content-length"), 0),
                        request.getQueryParameter("name"),
                        request.getQueryParameter("mime"));
            } else if ("POST".equals(method) && "/api/delete-request".equals(path)) {
                requestDelete(out, parseLong(request.getQueryParameter("id"), -1));
            } else {
                sendText(out, 404, "application/json", "{\"error\":\"not_found\"}");
            }
        } catch (Exception ignored) {}
    }

    private boolean validToken(String token) {
        String expected = context.getSharedPreferences("gallery_bridge", Context.MODE_PRIVATE)
                .getString("pair_token", "");
        return expected != null && !expected.isEmpty() && expected.equals(token);
    }

    private void sendMediaList(OutputStream out, Uri request) throws Exception {
        int limit = (int)Math.max(1, Math.min(500, parseLong(request.getQueryParameter("limit"), 200)));
        int offset = (int)Math.max(0, parseLong(request.getQueryParameter("offset"), 0));

        String[] projection = {
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                MediaStore.Files.FileColumns.MIME_TYPE,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.DATE_MODIFIED,
                MediaStore.Files.FileColumns.MEDIA_TYPE
        };
        String selection = MediaStore.Files.FileColumns.MEDIA_TYPE + "=? OR " +
                MediaStore.Files.FileColumns.MEDIA_TYPE + "=?";
        String[] args = {
                String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE),
                String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
        };

        JSONArray arr = new JSONArray();
        int seen = 0;
        int added = 0;
        try (Cursor c = context.getContentResolver().query(
                MediaStore.Files.getContentUri("external"),
                projection, selection, args,
                MediaStore.Files.FileColumns.DATE_MODIFIED + " DESC")) {
            if (c != null) {
                int idI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID);
                int nameI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME);
                int mimeI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE);
                int sizeI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE);
                int dateI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED);
                int typeI = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE);
                while (c.moveToNext()) {
                    if (seen++ < offset) continue;
                    if (added >= limit) break;
                    JSONObject o = new JSONObject();
                    o.put("id", c.getLong(idI));
                    o.put("name", c.getString(nameI));
                    o.put("mime", c.getString(mimeI));
                    o.put("size", c.getLong(sizeI));
                    o.put("date", c.getLong(dateI));
                    o.put("kind", c.getInt(typeI) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ? "video" : "image");
                    arr.put(o);
                    added++;
                }
            }
        }

        JSONObject root = new JSONObject();
        root.put("items", arr);
        root.put("offset", offset);
        root.put("count", added);
        sendText(out, 200, "application/json; charset=utf-8", root.toString());
    }

    private Uri mediaUri(long id) {
        return ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), id);
    }

    private void sendThumbnail(OutputStream out, long id) throws Exception {
        if (id < 0) { sendText(out, 400, "text/plain", "bad id"); return; }
        Uri uri = mediaUri(id);
        Bitmap bmp;
        if (Build.VERSION.SDK_INT >= 29) {
            bmp = context.getContentResolver().loadThumbnail(uri, new Size(360, 360), null);
        } else {
            try (InputStream input = context.getContentResolver().openInputStream(uri)) {
                bmp = BitmapFactory.decodeStream(input);
                if (bmp != null) {
                    int w = 360;
                    int h = Math.max(1, bmp.getHeight() * w / Math.max(1, bmp.getWidth()));
                    bmp = Bitmap.createScaledBitmap(bmp, w, h, true);
                }
            }
        }
        if (bmp == null) { sendText(out, 404, "text/plain", "thumbnail unavailable"); return; }
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, bytes);
        byte[] data = bytes.toByteArray();
        sendHeaders(out, 200, "image/jpeg", data.length);
        out.write(data);
        out.flush();
    }

    private void sendFile(OutputStream out, long id) throws Exception {
        if (id < 0) { sendText(out, 400, "text/plain", "bad id"); return; }
        Uri uri = mediaUri(id);
        String mime = context.getContentResolver().getType(uri);
        if (mime == null) mime = "application/octet-stream";

        try (android.content.res.AssetFileDescriptor afd =
                     context.getContentResolver().openAssetFileDescriptor(uri, "r")) {
            if (afd == null) { sendText(out, 404, "text/plain", "not found"); return; }
            long len = afd.getLength();
            sendHeaders(out, 200, mime, len);
            try (InputStream data = afd.createInputStream()) {
                byte[] buffer = new byte[64 * 1024];
                int n;
                while ((n = data.read(buffer)) >= 0) out.write(buffer, 0, n);
            }
            out.flush();
        }
    }

    private void receiveUpload(OutputStream out, InputStream in, long length, String name, String mime) throws Exception {
        if (length <= 0 || length > 1024L * 1024L * 1024L) {
            sendText(out, 400, "application/json", "{\"error\":\"invalid_length\"}");
            return;
        }
        if (name == null || name.trim().isEmpty()) name = "colorize_" + System.currentTimeMillis();
        if (mime == null || mime.trim().isEmpty()) mime = "application/octet-stream";

        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, mime);
        if (Build.VERSION.SDK_INT >= 29) {
            values.put(MediaStore.MediaColumns.RELATIVE_PATH,
                    mime.startsWith("video/") ? "Movies/ColorizeRemote" : "Pictures/ColorizeRemote");
            values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        }

        Uri collection = mime.startsWith("video/")
                ? MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                : MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);

        Uri item = context.getContentResolver().insert(collection, values);
        if (item == null) {
            sendText(out, 500, "application/json", "{\"error\":\"insert_failed\"}");
            return;
        }

        boolean ok = false;
        try (OutputStream mediaOut = context.getContentResolver().openOutputStream(item, "w")) {
            if (mediaOut == null) throw new IOException("open output failed");
            byte[] buffer = new byte[64 * 1024];
            long remain = length;
            while (remain > 0) {
                int n = in.read(buffer, 0, (int)Math.min(buffer.length, remain));
                if (n < 0) throw new EOFException();
                mediaOut.write(buffer, 0, n);
                remain -= n;
            }
            mediaOut.flush();
            ok = true;
        } finally {
            if (!ok) context.getContentResolver().delete(item, null, null);
        }

        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues done = new ContentValues();
            done.put(MediaStore.MediaColumns.IS_PENDING, 0);
            context.getContentResolver().update(item, done, null, null);
        }

        JSONObject response = new JSONObject();
        response.put("ok", true);
        response.put("uri", item.toString());
        sendText(out, 201, "application/json; charset=utf-8", response.toString());
    }

    private void requestDelete(OutputStream out, long id) throws Exception {
        if (id < 0) {
            sendText(out, 400, "application/json", "{\"error\":\"bad_id\"}");
            return;
        }
        String name = "";
        String[] projection = {MediaStore.Files.FileColumns.DISPLAY_NAME};
        try (Cursor c = context.getContentResolver().query(mediaUri(id), projection, null, null, null)) {
            if (c != null && c.moveToFirst()) name = c.getString(0);
        }
        GalleryBridgeService.notifyDeleteRequest(context, id, name);
        sendText(out, 202, "application/json",
                "{\"ok\":true,\"requires_android_confirmation\":true}");
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev = -1, cur;
        while ((cur = in.read()) != -1) {
            if (prev == '\r' && cur == '\n') break;
            if (prev != -1) b.write(prev);
            prev = cur;
            if (b.size() > 16384) throw new IOException("line too long");
        }
        if (cur == -1 && prev == -1) return null;
        if (cur == -1 && prev != -1) b.write(prev);
        return b.toString(StandardCharsets.UTF_8.name());
    }

    private static long parseLong(String value, long fallback) {
        try { return Long.parseLong(value == null ? "" : value); }
        catch (Exception e) { return fallback; }
    }

    private static void sendText(OutputStream out, int code, String type, String text) throws IOException {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        sendHeaders(out, code, type, data.length);
        out.write(data);
        out.flush();
    }

    private static void sendHeaders(OutputStream out, int code, String type, long length) throws IOException {
        String reason = code == 200 ? "OK" : code == 201 ? "Created" : code == 202 ? "Accepted" :
                code == 400 ? "Bad Request" : code == 401 ? "Unauthorized" :
                code == 404 ? "Not Found" : "Error";
        String headers = "HTTP/1.1 " + code + " " + reason + "\r\n" +
                "Content-Type: " + type + "\r\n" +
                "Content-Length: " + length + "\r\n" +
                "Connection: close\r\n" +
                "Cache-Control: no-store\r\n\r\n";
        out.write(headers.getBytes(StandardCharsets.US_ASCII));
    }
}
