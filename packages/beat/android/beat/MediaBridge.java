package beat;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.function.Consumer;
import java.util.function.IntSupplier;

/**
 * The media session, lock-screen controls and playback notification of a NativeActivity app.
 *
 * Lua cannot subclass MediaSession.Callback, so this class is in the APK's classes.dex and driven
 * only through framework interfaces Lua can call by name:
 *   accept(Context)  once, to set up on the main thread;
 *   accept(Bundle)   whenever what is playing changes (see the keys in `update`);
 *   getAsInt()       to take the next command a control sent, -1 when there is none. A seek is
 *                    one value too, -2 - the position in milliseconds, so it is never read half.
 * Every Android call happens on the main thread; the queue is the only state the Lua thread reads.
 */
public final class MediaBridge extends MediaSession.Callback implements Consumer<Object>, IntSupplier {
	public static final int PLAY = 1;
	public static final int PAUSE = 2;
	public static final int NEXT = 3;
	public static final int PREVIOUS = 4;
	public static final int STOP = 5;

	private static final String CHANNEL = "playback";
	private static final int NOTIFICATION = 1;
	private static final String ACTION = "beat.MEDIA_CONTROL";
	private static final long ACTIONS = PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
		| PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_SKIP_TO_NEXT
		| PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO | PlaybackState.ACTION_STOP;

	private final ConcurrentLinkedQueue<Integer> commands = new ConcurrentLinkedQueue<>();
	private final Handler main = new Handler(Looper.getMainLooper());

	private Context context;
	private MediaSession session;
	private NotificationManager notifications;
	private PendingIntent open;
	private String artPath;
	private Bitmap art;
	private Icon mark;

	@Override
	public int getAsInt() {
		Integer next = commands.poll();
		return next == null ? -1 : next;
	}

	@Override
	public void accept(Object value) {
		if (value instanceof Context) {
			Context given = (Context) value;
			main.post(() -> start(given));
		} else if (value instanceof Bundle) {
			Bundle state = (Bundle) value;
			main.post(() -> update(state));
		}
	}

	private void start(Context given) {
		if (session != null) return;
		context = given.getApplicationContext();
		notifications = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
		if (Build.VERSION.SDK_INT >= 26) {
			NotificationChannel channel = new NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW);
			channel.setShowBadge(false);
			notifications.createNotificationChannel(channel);
		}

		Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
		if (launch != null) {
			launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
			open = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE);
		}

		// The notification's buttons are broadcasts to this process; older systems draw them, newer
		// ones draw the session's own controls, which come back through the callback below.
		BroadcastReceiver receiver = new BroadcastReceiver() {
			@Override
			public void onReceive(Context ignored, Intent intent) {
				commands.add(intent.getIntExtra("command", -1));
			}
		};
		IntentFilter filter = new IntentFilter(ACTION);
		if (Build.VERSION.SDK_INT >= 33) {
			context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
		} else {
			context.registerReceiver(receiver, filter);
		}

		session = new MediaSession(context, "beat");
		session.setCallback(this, main);
		if (open != null) session.setSessionActivity(open);
		mark = drawMark();
	}

	/**
	 * The status bar's icon: beat's three bars, white on nothing. Android draws a small icon from its
	 * alpha alone, so the launcher icon -- a filled square -- shows as a blank tile. The bars are
	 * icon.svg's, framed to fill the square the way system icons do.
	 */
	private static Icon drawMark() {
		int side = 96;
		Bitmap bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888);
		Canvas canvas = new Canvas(bitmap);
		Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
		paint.setColor(0xffffffff);
		// icon.svg's bars span x 142-370 and y 140-372 of 512; that box is fitted into the square
		// with an eighth of it left as margin on each side.
		float scale = side * 0.75f / 232f;
		float left = (side - 228f * scale) / 2f - 142f * scale;
		float top = (side - 232f * scale) / 2f - 140f * scale;
		float[][] bars = { { 142, 198, 314 }, { 228, 140, 372 }, { 314, 176, 336 } };
		for (float[] bar : bars) {
			float x = left + bar[0] * scale;
			canvas.drawRoundRect(x, top + bar[1] * scale, x + 56 * scale, top + bar[2] * scale,
				28 * scale, 28 * scale, paint);
		}
		return Icon.createWithBitmap(bitmap);
	}

	/**
	 * Keys: "active" (boolean; false drops the notification and the session's controls), "title",
	 * "artist", "album", "art" (a picture file), "duration" and "position" (milliseconds) and
	 * "playing" (boolean).
	 */
	private void update(Bundle state) {
		if (session == null) return;

		if (!state.getBoolean("active")) {
			PlaybackService.release();
			notifications.cancel(NOTIFICATION);
			session.setActive(false);
			return;
		}

		String title = state.getString("title", "");
		String artist = state.getString("artist", "");
		String album = state.getString("album", "");
		boolean playing = state.getBoolean("playing");
		loadArt(state.getString("art"));

		MediaMetadata.Builder metadata = new MediaMetadata.Builder()
			.putString(MediaMetadata.METADATA_KEY_TITLE, title)
			.putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
			.putString(MediaMetadata.METADATA_KEY_ALBUM, album)
			.putLong(MediaMetadata.METADATA_KEY_DURATION, state.getLong("duration"));
		if (art != null) metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art);
		session.setMetadata(metadata.build());

		session.setPlaybackState(new PlaybackState.Builder()
			.setActions(ACTIONS)
			.setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
				state.getLong("position"), playing ? 1f : 0f, SystemClock.elapsedRealtime())
			.build());
		session.setActive(true);

		Notification.Builder builder = Build.VERSION.SDK_INT >= 26
			? new Notification.Builder(context, CHANNEL)
			: new Notification.Builder(context);
		builder
			.setSmallIcon(mark)
			.setContentTitle(title)
			.setContentText(artist)
			.setSubText(album)
			.setLargeIcon(art)
			.setVisibility(Notification.VISIBILITY_PUBLIC)
			.setShowWhen(false)
			.setOnlyAlertOnce(true)
			.setDeleteIntent(control(STOP))
			.addAction(new Notification.Action.Builder(android.R.drawable.ic_media_previous, "Previous", control(PREVIOUS)).build())
			.addAction(playing
				? new Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause", control(PAUSE)).build()
				: new Notification.Action.Builder(android.R.drawable.ic_media_play, "Play", control(PLAY)).build())
			.addAction(new Notification.Action.Builder(android.R.drawable.ic_media_next, "Next", control(NEXT)).build())
			.setStyle(new Notification.MediaStyle()
				.setMediaSession(session.getSessionToken())
				.setShowActionsInCompactView(0, 1, 2));
		if (open != null) builder.setContentIntent(open);
		Notification shown = builder.build();
		notifications.notify(NOTIFICATION, shown);
		// While it plays the app has to keep running off screen, which only a foreground service
		// earns it; paused, it gives that up and keeps the notification.
		if (playing) {
			PlaybackService.hold(context, shown);
		} else {
			PlaybackService.release();
		}
	}

	private PendingIntent control(int command) {
		Intent intent = new Intent(ACTION).setPackage(context.getPackageName()).putExtra("command", command);
		return PendingIntent.getBroadcast(context, command, intent,
			PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
	}

	/** A cover at most 512 pixels across, decoded once per picture. */
	private void loadArt(String path) {
		if (path == null || path.isEmpty()) {
			artPath = null;
			art = null;
			return;
		}
		if (path.equals(artPath)) return;
		artPath = path;
		BitmapFactory.Options bounds = new BitmapFactory.Options();
		bounds.inJustDecodeBounds = true;
		BitmapFactory.decodeFile(path, bounds);
		BitmapFactory.Options options = new BitmapFactory.Options();
		int side = Math.max(bounds.outWidth, bounds.outHeight);
		options.inSampleSize = 1;
		while (side / (options.inSampleSize * 2) >= 512) options.inSampleSize *= 2;
		art = BitmapFactory.decodeFile(path, options);
	}

	@Override
	public void onPlay() { commands.add(PLAY); }

	@Override
	public void onPause() { commands.add(PAUSE); }

	@Override
	public void onSkipToNext() { commands.add(NEXT); }

	@Override
	public void onSkipToPrevious() { commands.add(PREVIOUS); }

	@Override
	public void onStop() { commands.add(STOP); }

	@Override
	public void onSeekTo(long position) {
		commands.add(-2 - (int) Math.min(Integer.MAX_VALUE - 2, Math.max(0, position)));
	}
}
