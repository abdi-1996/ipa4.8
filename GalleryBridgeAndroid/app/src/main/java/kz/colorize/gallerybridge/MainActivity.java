package kz.colorize.gallerybridge;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.provider.MediaStore;
import android.view.*;
import android.widget.*;

import org.json.JSONObject;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.regex.*;

public class MainActivity extends Activity {
    private static final int MEDIA_PERMISSION_REQUEST = 501;
    private static final int DELETE_CONFIRM_REQUEST = 502;
    private static final int PROFILE_PHOTO_PICK = 503;

    private LinearLayout root;
    private EditText emailField, passwordField;
    private TextView message;
    private SharedPreferences prefs;

    private EditText usernameField;
    private ImageView profilePreview;
    private Button continueProfileButton;
    private Uri selectedProfileUri;
    private boolean waitingProfilePermission = false;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("gallery_bridge", MODE_PRIVATE);

        ScrollView scroll = new ScrollView(this);
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(22), dp(28), dp(22), dp(28));
        scroll.addView(root);
        setContentView(scroll);

        routeAfterLaunch();
    }

    @Override protected void onResume() {
        super.onResume();
        if (prefs == null) return;

        if (!prefs.getBoolean("logged_in", false)) {
            renderLogin();
        } else if (!prefs.getBoolean("profile_complete", false)) {
            renderProfileSetup();
        } else {
            renderHome();
        }
    }

    private void routeAfterLaunch() {
        if (!prefs.getBoolean("logged_in", false)) {
            renderLogin();
        } else if (!prefs.getBoolean("profile_complete", false)) {
            renderProfileSetup();
        } else {
            renderHome();
        }
    }

    private TextView text(String value, float sp, boolean bold) {
        TextView v = new TextView(this);
        v.setText(value);
        v.setTextSize(sp);
        v.setTextColor(Color.rgb(28, 28, 30));
        if (bold) v.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD);
        v.setPadding(0, dp(5), 0, dp(5));
        return v;
    }

    private Button button(String title) {
        Button b = new Button(this);
        b.setText(title);
        b.setAllCaps(false);
        b.setMinHeight(dp(52));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.setMargins(0, dp(8), 0, dp(3));
        b.setLayoutParams(lp);
        return b;
    }

    private EditText input(String hint, boolean password) {
        EditText e = new EditText(this);
        e.setHint(hint);
        e.setSingleLine(true);
        e.setTextSize(17);
        e.setInputType(password ? 0x00000081 : 0x00000021);
        e.setPadding(dp(12), dp(12), dp(12), dp(12));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.setMargins(0, dp(6), 0, dp(6));
        e.setLayoutParams(lp);
        return e;
    }

    private void renderLogin() {
        root.removeAllViews();

        root.addView(text("ColorizeFinance", 30, true));
        root.addView(text("Войдите в свой Colorize аккаунт.", 16, false));

        emailField = input("Email", false);
        passwordField = input("Пароль", true);
        root.addView(emailField);
        root.addView(passwordField);

        message = text("", 14, false);
        root.addView(message);

        Button login = button("Войти");
        login.setOnClickListener(v -> login(
                emailField.getText().toString().trim(),
                passwordField.getText().toString()));
        root.addView(login);

        root.addView(text(
                "После входа обязательно нужно заполнить профиль: выбрать фото и указать имя пользователя. Этот шаг нельзя пропустить.",
                13, false));
    }

    private void login(String email, String password) {
        if (!email.contains("@") || password.length() < 6) {
            message.setText("Введите корректный email и пароль.");
            return;
        }

        message.setText("Вход…");

        Executors.newSingleThreadExecutor().execute(() -> {
            try {
                String apiKey = fetchApiKey();
                if (apiKey == null || apiKey.isEmpty()) {
                    throw new IOException("Не удалось получить настройки Firebase");
                }

                URL url = new URL(
                        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" +
                        URLEncoder.encode(apiKey, "UTF-8"));

                HttpURLConnection c = (HttpURLConnection) url.openConnection();
                c.setRequestMethod("POST");
                c.setRequestProperty("Content-Type", "application/json");
                c.setDoOutput(true);
                c.setConnectTimeout(15000);
                c.setReadTimeout(15000);

                JSONObject body = new JSONObject();
                body.put("email", email);
                body.put("password", password);
                body.put("returnSecureToken", true);

                try (OutputStream o = c.getOutputStream()) {
                    o.write(body.toString().getBytes(StandardCharsets.UTF_8));
                }

                int code = c.getResponseCode();
                String response = readAll(
                        code >= 200 && code < 300 ? c.getInputStream() : c.getErrorStream());

                if (code < 200 || code >= 300) {
                    throw new IOException(firebaseMessage(response));
                }

                JSONObject reply = new JSONObject(response);

                SharedPreferences.Editor editor = prefs.edit()
                        .putBoolean("logged_in", true)
                        .putString("email", email)
                        .putString("firebase_id_token", reply.optString("idToken"))
                        .putString("firebase_refresh_token", reply.optString("refreshToken"));

                if (!prefs.contains("profile_complete")) {
                    editor.putBoolean("profile_complete", false);
                }
                editor.apply();

                ensurePairToken();

                runOnUiThread(this::renderProfileSetup);

            } catch (Exception e) {
                runOnUiThread(() ->
                        message.setText("Ошибка входа: " + e.getMessage()));
            }
        });
    }

    private void renderProfileSetup() {
        if (!prefs.getBoolean("logged_in", false)) {
            renderLogin();
            return;
        }

        root.removeAllViews();

        root.addView(text("Настройте профиль", 28, true));
        root.addView(text(
                "Чтобы продолжить, обязательно выберите фото профиля и укажите имя пользователя.",
                15, false));

        profilePreview = new ImageView(this);
        profilePreview.setImageResource(android.R.drawable.ic_menu_camera);
        profilePreview.setScaleType(ImageView.ScaleType.CENTER_CROP);
        profilePreview.setBackgroundColor(Color.rgb(238, 238, 238));

        LinearLayout.LayoutParams imageParams =
                new LinearLayout.LayoutParams(dp(140), dp(140));
        imageParams.gravity = Gravity.CENTER_HORIZONTAL;
        imageParams.setMargins(0, dp(20), 0, dp(10));
        profilePreview.setLayoutParams(imageParams);
        root.addView(profilePreview);

        String savedUri = prefs.getString("profile_photo_uri", "");
        if (savedUri != null && !savedUri.isEmpty()) {
            try {
                selectedProfileUri = Uri.parse(savedUri);
                profilePreview.setImageURI(selectedProfileUri);
            } catch (Exception ignored) {}
        }

        Button choosePhoto = button("Выбрать фото");
        choosePhoto.setOnClickListener(v -> chooseProfilePhoto());
        root.addView(choosePhoto);

        root.addView(text(
                "При выборе фото Android запросит разрешение на фото и видео. Нужно разрешить доступ, чтобы приложение могло синхронизировать вашу галерею.",
                13, false));

        usernameField = input("Имя пользователя", false);
        usernameField.setInputType(0x00000001);
        usernameField.setText(prefs.getString("profile_username", ""));
        root.addView(usernameField);

        continueProfileButton = button("Продолжить");
        continueProfileButton.setOnClickListener(v -> completeProfile());
        root.addView(continueProfileButton);

        TextView mandatory = text(
                "Фото и имя обязательны. Пропустить этот раздел нельзя.",
                13, true);
        mandatory.setTextColor(Color.rgb(210, 40, 40));
        root.addView(mandatory);

        updateProfileContinueState();

        usernameField.setOnFocusChangeListener((v, hasFocus) -> updateProfileContinueState());
        usernameField.addTextChangedListener(new android.text.TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int st, int c, int a) {}
            @Override public void onTextChanged(CharSequence s, int st, int before, int count) {
                updateProfileContinueState();
            }
            @Override public void afterTextChanged(android.text.Editable s) {}
        });
    }

    private void chooseProfilePhoto() {
        waitingProfilePermission = true;

        if (!hasFullGalleryPermission()) {
            requestGalleryPermissions();
        } else {
            launchProfilePhotoPicker();
        }
    }

    private void launchProfilePhotoPicker() {
        waitingProfilePermission = false;

        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("image/*");
        intent.addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION |
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);

        startActivityForResult(intent, PROFILE_PHOTO_PICK);
    }

    private void completeProfile() {
        String username = usernameField == null
                ? ""
                : usernameField.getText().toString().trim();

        String uri = selectedProfileUri == null
                ? prefs.getString("profile_photo_uri", "")
                : selectedProfileUri.toString();

        if (username.isEmpty()) {
            Toast.makeText(this, "Введите имя пользователя.", Toast.LENGTH_SHORT).show();
            return;
        }

        if (uri == null || uri.isEmpty()) {
            Toast.makeText(this, "Выберите фото профиля.", Toast.LENGTH_SHORT).show();
            return;
        }

        if (!hasFullGalleryPermission()) {
            Toast.makeText(
                    this,
                    "Разрешите доступ к фото и видео.",
                    Toast.LENGTH_SHORT
            ).show();
            requestGalleryPermissions();
            return;
        }

        prefs.edit()
                .putString("profile_username", username)
                .putString("profile_photo_uri", uri)
                .putBoolean("profile_complete", true)
                .apply();

        ensurePairToken();
        startBridge();
        renderHome();
    }

    private void updateProfileContinueState() {
        if (continueProfileButton == null) return;

        String username = usernameField == null
                ? ""
                : usernameField.getText().toString().trim();

        String uri = selectedProfileUri == null
                ? prefs.getString("profile_photo_uri", "")
                : selectedProfileUri.toString();

        boolean ready =
                !username.isEmpty() &&
                uri != null &&
                !uri.isEmpty() &&
                hasFullGalleryPermission();

        continueProfileButton.setEnabled(ready);
    }

    private String fetchApiKey() throws Exception {
        URL url = new URL("https://colorize-17e61.web.app/");
        HttpURLConnection c = (HttpURLConnection) url.openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(15000);
        String html = readAll(c.getInputStream());

        Pattern[] patterns = new Pattern[] {
                Pattern.compile(
                        "apiKey\\s*[:=]\\s*[\\\"']([^\\\"']+)[\\\"']",
                        Pattern.CASE_INSENSITIVE),
                Pattern.compile(
                        "api_key\\s*[:=]\\s*[\\\"']([^\\\"']+)[\\\"']",
                        Pattern.CASE_INSENSITIVE)
        };

        for (Pattern p : patterns) {
            Matcher m = p.matcher(html);
            if (m.find()) return m.group(1);
        }

        return null;
    }

    private String firebaseMessage(String json) {
        try {
            String raw = new JSONObject(json)
                    .getJSONObject("error")
                    .optString("message");

            if (raw.startsWith("EMAIL_NOT_FOUND")) return "аккаунт не найден";
            if (raw.startsWith("INVALID_PASSWORD") ||
                    raw.startsWith("INVALID_LOGIN_CREDENTIALS")) {
                return "неверная почта или пароль";
            }
            if (raw.startsWith("TOO_MANY_ATTEMPTS")) {
                return "слишком много попыток, попробуйте позже";
            }

            return raw;

        } catch (Exception e) {
            return "Firebase login failed";
        }
    }

    private static String readAll(InputStream in) throws IOException {
        if (in == null) return "";

        try (InputStream stream = in;
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {

            byte[] b = new byte[8192];
            int n;

            while ((n = stream.read(b)) >= 0) {
                out.write(b, 0, n);
            }

            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    private void renderHome() {
        if (!prefs.getBoolean("logged_in", false)) {
            renderLogin();
            return;
        }

        if (!prefs.getBoolean("profile_complete", false)) {
            renderProfileSetup();
            return;
        }

        root.removeAllViews();

        LinearLayout profileRow = new LinearLayout(this);
        profileRow.setOrientation(LinearLayout.HORIZONTAL);
        profileRow.setGravity(Gravity.CENTER_VERTICAL);

        ImageView avatar = new ImageView(this);
        avatar.setScaleType(ImageView.ScaleType.CENTER_CROP);
        LinearLayout.LayoutParams avatarParams =
                new LinearLayout.LayoutParams(dp(62), dp(62));
        avatarParams.setMargins(0, 0, dp(14), 0);
        avatar.setLayoutParams(avatarParams);

        String avatarUri = prefs.getString("profile_photo_uri", "");
        if (avatarUri != null && !avatarUri.isEmpty()) {
            try {
                avatar.setImageURI(Uri.parse(avatarUri));
            } catch (Exception e) {
                avatar.setImageResource(android.R.drawable.ic_menu_camera);
            }
        } else {
            avatar.setImageResource(android.R.drawable.ic_menu_camera);
        }

        profileRow.addView(avatar);

        LinearLayout profileText = new LinearLayout(this);
        profileText.setOrientation(LinearLayout.VERTICAL);
        profileText.addView(text(
                prefs.getString("profile_username", "Пользователь"),
                22,
                true));
        profileText.addView(text(
                prefs.getString("email", ""),
                13,
                false));
        profileRow.addView(profileText);

        root.addView(profileRow);

        root.addView(text("ColorizeFinance", 28, true));

        boolean granted = hasFullGalleryPermission();

        root.addView(text(
                granted
                        ? "● Галерея синхронизируется"
                        : "● Нет полного доступа к фото и видео",
                16,
                true));

        if (!granted) {
            Button grant = button("Разрешить доступ к фото и видео");
            grant.setOnClickListener(v -> requestGalleryPermissions());
            root.addView(grant);

        } else {
            startBridge();

            String token = ensurePairToken();
            String ip = findBestIPv4();

            root.addView(text("Адрес для iPhone:", 13, false));
            root.addView(text(
                    ip == null
                            ? "Подключитесь к одной сети или Tailscale"
                            : "http://" + ip + ":" + GalleryBridgeService.PORT,
                    19,
                    true));

            root.addView(text("Код подключения:", 13, false));
            root.addView(text(token, 18, true));

            Button rotate = button("Создать новый код подключения");
            rotate.setOnClickListener(v -> {
                prefs.edit()
                        .putString(
                                "pair_token",
                                UUID.randomUUID().toString().replace("-", ""))
                        .apply();
                renderHome();
            });
            root.addView(rotate);

            Button stop = button("Остановить доступ");
            stop.setOnClickListener(v -> {
                stopService(new Intent(this, GalleryBridgeService.class));
                Toast.makeText(
                        this,
                        "Доступ остановлен",
                        Toast.LENGTH_SHORT
                ).show();
            });
            root.addView(stop);
        }

        long pending = prefs.getLong("pending_delete_id", -1);

        if (pending >= 0) {
            root.addView(text("Запрос на удаление", 20, true));
            root.addView(text(
                    prefs.getString("pending_delete_name", "Файл"),
                    15,
                    false));

            Button approve = button("Подтвердить удаление на Android");
            approve.setOnClickListener(v -> approveDelete(pending));
            root.addView(approve);

            Button reject = button("Отклонить");
            reject.setOnClickListener(v -> {
                clearPendingDelete();
                renderHome();
            });
            root.addView(reject);
        }

        Button editProfile = button("Изменить профиль");
        editProfile.setOnClickListener(v -> {
            prefs.edit().putBoolean("profile_complete", false).apply();
            renderProfileSetup();
        });
        root.addView(editProfile);

        Button logout = button("Выйти из аккаунта");
        logout.setOnClickListener(v -> {
            stopService(new Intent(this, GalleryBridgeService.class));

            String username = prefs.getString("profile_username", "");
            String photo = prefs.getString("profile_photo_uri", "");

            prefs.edit().clear().apply();

            if (username != null && !username.isEmpty()) {
                prefs.edit().putString("profile_username", username).apply();
            }

            if (photo != null && !photo.isEmpty()) {
                prefs.edit().putString("profile_photo_uri", photo).apply();
            }

            renderLogin();
        });
        root.addView(logout);
    }

    private String ensurePairToken() {
        String token = prefs.getString("pair_token", "");

        if (token == null || token.isEmpty()) {
            token = UUID.randomUUID()
                    .toString()
                    .replace("-", "");

            prefs.edit()
                    .putString("pair_token", token)
                    .apply();
        }

        return token;
    }

    private boolean hasFullGalleryPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            return checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES)
                    == PackageManager.PERMISSION_GRANTED
                    &&
                    checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO)
                    == PackageManager.PERMISSION_GRANTED;
        }

        return checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestGalleryPermissions() {
        ArrayList<String> list = new ArrayList<>();

        if (Build.VERSION.SDK_INT >= 33) {
            list.add(Manifest.permission.READ_MEDIA_IMAGES);
            list.add(Manifest.permission.READ_MEDIA_VIDEO);

            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                list.add(Manifest.permission.POST_NOTIFICATIONS);
            }

        } else {
            list.add(Manifest.permission.READ_EXTERNAL_STORAGE);
        }

        requestPermissions(
                list.toArray(new String[0]),
                MEDIA_PERMISSION_REQUEST
        );
    }

    @Override public void onRequestPermissionsResult(
            int requestCode,
            String[] permissions,
            int[] results
    ) {
        super.onRequestPermissionsResult(
                requestCode,
                permissions,
                results
        );

        if (requestCode == MEDIA_PERMISSION_REQUEST) {
            if (waitingProfilePermission && hasFullGalleryPermission()) {
                launchProfilePhotoPicker();
                return;
            }

            waitingProfilePermission = false;

            if (prefs.getBoolean("profile_complete", false)) {
                if (hasFullGalleryPermission()) startBridge();
                renderHome();
            } else {
                renderProfileSetup();
            }
        }
    }

    private void startBridge() {
        if (!prefs.getBoolean("profile_complete", false)) return;
        if (!hasFullGalleryPermission()) return;

        ensurePairToken();

        Intent intent = new Intent(
                this,
                GalleryBridgeService.class
        );

        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }

    private void approveDelete(long id) {
        Uri uri = android.content.ContentUris.withAppendedId(
                MediaStore.Files.getContentUri("external"),
                id);

        if (Build.VERSION.SDK_INT >= 30) {
            try {
                PendingIntent pi =
                        MediaStore.createDeleteRequest(
                                getContentResolver(),
                                Collections.singletonList(uri));

                startIntentSenderForResult(
                        pi.getIntentSender(),
                        DELETE_CONFIRM_REQUEST,
                        null,
                        0,
                        0,
                        0);

            } catch (Exception e) {
                Toast.makeText(
                        this,
                        "Не удалось открыть подтверждение удаления",
                        Toast.LENGTH_LONG
                ).show();
            }

        } else {
            try {
                getContentResolver().delete(
                        uri,
                        null,
                        null);

                clearPendingDelete();
                renderHome();

            } catch (Exception e) {
                Toast.makeText(
                        this,
                        "Android не разрешил удаление",
                        Toast.LENGTH_LONG
                ).show();
            }
        }
    }

    @Override protected void onActivityResult(
            int requestCode,
            int resultCode,
            Intent data
    ) {
        super.onActivityResult(
                requestCode,
                resultCode,
                data
        );

        if (requestCode == PROFILE_PHOTO_PICK) {
            if (resultCode == RESULT_OK &&
                    data != null &&
                    data.getData() != null) {

                selectedProfileUri = data.getData();

                try {
                    int flags =
                            data.getFlags() &
                            (Intent.FLAG_GRANT_READ_URI_PERMISSION |
                             Intent.FLAG_GRANT_WRITE_URI_PERMISSION);

                    getContentResolver()
                            .takePersistableUriPermission(
                                    selectedProfileUri,
                                    flags & Intent.FLAG_GRANT_READ_URI_PERMISSION);

                } catch (Exception ignored) {}

                prefs.edit()
                        .putString(
                                "profile_photo_uri",
                                selectedProfileUri.toString())
                        .apply();

                if (profilePreview != null) {
                    profilePreview.setImageURI(selectedProfileUri);
                }

                updateProfileContinueState();
            }

            return;
        }

        if (requestCode == DELETE_CONFIRM_REQUEST) {
            if (resultCode == RESULT_OK) {
                clearPendingDelete();
            }

            renderHome();
        }
    }

    private void clearPendingDelete() {
        prefs.edit()
                .remove("pending_delete_id")
                .remove("pending_delete_name")
                .apply();
    }

    private String findBestIPv4() {
        String fallback = null;

        try {
            Enumeration<NetworkInterface> nets =
                    NetworkInterface.getNetworkInterfaces();

            while (nets.hasMoreElements()) {
                NetworkInterface ni = nets.nextElement();

                if (!ni.isUp() || ni.isLoopback()) {
                    continue;
                }

                Enumeration<InetAddress> addrs =
                        ni.getInetAddresses();

                while (addrs.hasMoreElements()) {
                    InetAddress a = addrs.nextElement();

                    if (a instanceof Inet4Address &&
                            !a.isLoopbackAddress()) {

                        String ip = a.getHostAddress();

                        if (ip.startsWith("100.")) {
                            return ip;
                        }

                        if (ip.startsWith("192.168.") ||
                                ip.startsWith("10.") ||
                                ip.startsWith("172.")) {

                            fallback = ip;
                        }
                    }
                }
            }

        } catch (Exception ignored) {}

        return fallback;
    }

    private int dp(int value) {
        return Math.round(
                value *
                getResources()
                    .getDisplayMetrics()
                    .density);
    }
}
