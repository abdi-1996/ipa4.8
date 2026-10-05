package kz.colorize.gallerybridge;

import android.app.*;
import android.content.*;
import android.os.Build;
import androidx.core.app.NotificationCompat;

public class GalleryBridgeService extends Service {
    public static final int PORT = 8787;
    private static final String CHANNEL = "colorize_gallery_bridge";
    private MediaServer server;

    @Override public void onCreate() {
        super.onCreate();
        createChannel();
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_gallery)
                .setContentTitle("Colorize Gallery")
                .setContentText("Доступ к вашей галерее активен")
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
        startForeground(41, n);
        server = new MediaServer(this, PORT);
        server.start();
    }

    @Override public void onDestroy() {
        if (server != null) server.shutdown();
        super.onDestroy();
    }

    @Override public android.os.IBinder onBind(Intent intent) { return null; }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL, "Colorize Gallery access", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("Показывает, когда доступ к галерее с вашего iPhone активен.");
            getSystemService(NotificationManager.class).createNotificationChannel(ch);
        }
    }

    public static void notifyDeleteRequest(Context context, long mediaId, String name) {
        context.getSharedPreferences("gallery_bridge", MODE_PRIVATE).edit()
                .putLong("pending_delete_id", mediaId)
                .putString("pending_delete_name", name == null ? "" : name)
                .apply();

        Intent open = new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(
                context, 77, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        Notification n = new NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_delete)
                .setContentTitle("Подтвердите удаление")
                .setContentText(name == null || name.isEmpty() ? "Откройте приложение" : name)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build();
        context.getSystemService(NotificationManager.class).notify(77, n);
    }
}
