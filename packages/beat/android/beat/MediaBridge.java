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
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
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
 *                    Audio focus changes and a media stream falling silent arrive the same way;
 *   run()            to drop the notification, the foreground service and the session for good,
 *                    before the process leaves, and wait until it is done.
 * Every Android call happens on the main thread; the queue is the only state the Lua thread reads.
 */
public final class MediaBridge extends MediaSession.Callback
	implements Consumer<Object>, IntSupplier, Runnable {
	public static final int PLAY = 1;
	public static final int PAUSE = 2;
	public static final int NEXT = 3;
	public static final int PREVIOUS = 4;
	public static final int STOP = 5;
	/** Playback paused because another app took focus for a while; the gain that follows resumes it. */
	public static final int FOCUS_PAUSE = 6;
	/** The other app is done: play again what the transient loss paused. */
	public static final int FOCUS_RESUME = 7;
	/** Another app took focus for good: pause and stay paused. */
	public static final int FOCUS_LOSS = 8;
	/** The media volume reached zero while playing: pause and stay paused. */
	public static final int VOLUME_ZERO = 9;
	/** The player's X: stop, drop the notification and the session, and leave the app. */
	public static final int CLOSE = 10;

	private static final String CHANNEL = "playback";
	private static final int NOTIFICATION = 1;
	private static final String ACTION = "beat.MEDIA_CONTROL";
	/** The PlaybackState custom action whose button is the player's X, on Android 13 and later. */
	private static final String ACTION_CLOSE = "beat.MEDIA_CLOSE";
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

	private AudioManager audio;
	private AudioFocusRequest focusRequest;
	/** Whether the session currently holds audio focus, or believes it does. */
	private boolean focusHeld;
	/** Whether this bridge is the one that paused playback, so the next gain may resume it. */
	private boolean pausedByFocus;
	/** Whether losing focus and a silent media stream should pause, from "Pause for other audio". */
	private boolean pauseForOtherAudio = true;
	/** Whether playback is playing, as of the last report; the focus callback reads it. */
	private boolean playing;
	/** Whether the session has been made active, so a repeat report need not tell it again. */
	private boolean active;
	/** What the last report showed, so one that only moved the playhead need not rebuild it. */
	private String reportedTitle;
	private String reportedArtist;
	private String reportedAlbum;
	private long reportedDuration;
	private boolean watchingVolume;
	private int lastVolume;

	private final AudioManager.OnAudioFocusChangeListener focusListener = this::onFocusChange;

	/** Hears the media stream's volume change while playing, and not at all otherwise. */
	private final BroadcastReceiver volumeReceiver = new BroadcastReceiver() {
		@Override
		public void onReceive(Context ignored, Intent intent) {
			if (intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1) != AudioManager.STREAM_MUSIC) return;
			int volume = audio == null ? -1 : audio.getStreamVolume(AudioManager.STREAM_MUSIC);
			if (pauseForOtherAudio && playing && volume == 0 && lastVolume > 0) {
				commands.add(VOLUME_ZERO);
			}
			if (volume >= 0) lastVolume = volume;
		}
	};

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
		audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
		if (Build.VERSION.SDK_INT >= 26 && audio != null) {
			focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
				.setAudioAttributes(new AudioAttributes.Builder()
					.setUsage(AudioAttributes.USAGE_MEDIA)
					.setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
					.build())
				.setOnAudioFocusChangeListener(focusListener, main)
				// Ducking is the system's job: it lowers this stream itself on API 26 and later.
				.setWillPauseWhenDucked(false)
				.build();
		}
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
	 * "artist", "album", "art" (a picture file), "duration" and "position" (milliseconds),
	 * "playing" (boolean) and "pauseForOtherAudio" (boolean).
	 */
	private void update(Bundle state) {
		if (session == null) return;

		boolean pauseBefore = pauseForOtherAudio;
		pauseForOtherAudio = state.getBoolean("pauseForOtherAudio", true);
		if (!pauseForOtherAudio) pausedByFocus = false;
		if (!state.getBoolean("active")) {
			playing = false;
			active = false;
			pausedByFocus = false;
			stopVolumeWatch();
			abandonFocus();
			PlaybackService.release();
			notifications.cancel(NOTIFICATION);
			session.setActive(false);
			// The notification and the cover are what keep the album art in memory; both are gone
			// now, and the next report starts afresh.
			artPath = null;
			art = null;
			reportedTitle = null;
			reportedArtist = null;
			reportedAlbum = null;
			reportedDuration = 0;
			return;
		}

		String title = state.getString("title", "");
		String artist = state.getString("artist", "");
		String album = state.getString("album", "");
		String cover = state.getString("art");
		if (cover != null && cover.isEmpty()) cover = null;
		long duration = state.getLong("duration");
		long position = state.getLong("position");
		boolean plays = state.getBoolean("playing");
		boolean wasPlaying = playing;
		// Playback starting from a stop means the listener asked for it, even if it was a focus
		// pause; a repeat report while it already plays must not drop a pause a loss just made.
		if (plays && !wasPlaying) pausedByFocus = false;

		boolean sameTrack = active
			&& title.equals(reportedTitle)
			&& artist.equals(reportedArtist)
			&& album.equals(reportedAlbum)
			&& duration == reportedDuration
			&& (cover == null ? artPath == null : cover.equals(artPath));
		if (sameTrack && plays == wasPlaying && pauseBefore == pauseForOtherAudio) {
			// Only the playhead moved: the session's own copy advances while it plays, so the
			// state alone needs the new position. No metadata, no notification, no new bitmap.
			session.setPlaybackState(playbackState(plays, position));
			return;
		}

		playing = plays;
		applyFocus(plays);
		if (plays && pauseForOtherAudio) {
			startVolumeWatch();
		} else {
			stopVolumeWatch();
		}
		loadArt(cover);
		reportedTitle = title;
		reportedArtist = artist;
		reportedAlbum = album;
		reportedDuration = duration;

		MediaMetadata.Builder metadata = new MediaMetadata.Builder()
			.putString(MediaMetadata.METADATA_KEY_TITLE, title)
			.putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
			.putString(MediaMetadata.METADATA_KEY_ALBUM, album)
			.putLong(MediaMetadata.METADATA_KEY_DURATION, duration);
		if (art != null) metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art);
		session.setMetadata(metadata.build());

		session.setPlaybackState(playbackState(plays, position));
		if (!active) {
			session.setActive(true);
			active = true;
		}

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
			// Swiping a paused player away is the same thing the X says: nothing is listening any
			// more, so beat goes. A playing one is not dismissible on Android 13 and later, and the
			// pause it sent before that only stops the sound.
			.setDeleteIntent(plays ? control(STOP) : control(CLOSE))
			.addAction(new Notification.Action.Builder(android.R.drawable.ic_media_previous, "Previous", control(PREVIOUS)).build())
			.addAction(plays
				? new Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause", control(PAUSE)).build()
				: new Notification.Action.Builder(android.R.drawable.ic_media_play, "Play", control(PLAY)).build())
			.addAction(new Notification.Action.Builder(android.R.drawable.ic_media_next, "Next", control(NEXT)).build())
			// The fourth button older Android draws in the expanded notification. Android 13 and
			// later ignore it and draw the X from the session's state instead. The compact view is
			// still the three transport controls.
			.addAction(new Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Close", control(CLOSE)).build())
			.setStyle(new Notification.MediaStyle()
				.setMediaSession(session.getSessionToken())
				.setShowActionsInCompactView(0, 1, 2));
		if (open != null) builder.setContentIntent(open);
		Notification shown = builder.build();
		notifications.notify(NOTIFICATION, shown);
		// While it plays the app has to keep running off screen, which only a foreground service
		// earns it; paused, it gives that up and keeps the notification. Promoting it again on
		// every report is a second startForeground, so only the start of playback does it.
		if (plays) {
			if (!wasPlaying) PlaybackService.hold(context, shown);
		} else {
			PlaybackService.release();
		}
	}

	/** The session's view of playback, at `position` milliseconds. */
	private PlaybackState playbackState(boolean plays, long position) {
		// Android 13 and later draw the shade's player from this, not from the notification's
		// buttons: a custom action is the only way to put an X among its controls. The icon is a
		// resource id, which the system resolves and tints with the other buttons.
		return new PlaybackState.Builder()
			.setActions(ACTIONS)
			.setState(plays ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
				position, plays ? 1f : 0f, SystemClock.elapsedRealtime())
			.addCustomAction(ACTION_CLOSE, "Close", android.R.drawable.ic_menu_close_clear_cancel)
			.build();
	}

	@Override
	public void onCustomAction(String action, Bundle extras) {
		if (ACTION_CLOSE.equals(action)) commands.add(CLOSE);
	}

	/**
	 * Drops the notification, the foreground service and the session for good. Lua asks for this
	 * before the process leaves: a report posted to the main thread would still be waiting when the
	 * loop returns and `os.exit` ends the process, and the notification would be left behind.
	 *
	 * The teardown happens on the main thread, where the notification and the service belong; the
	 * caller waits for it, up to a second, so nothing outlives the call.
	 */
	@Override
	public void run() {
		if (Looper.myLooper() == Looper.getMainLooper()) {
			shutDown();
			return;
		}
		CountDownLatch done = new CountDownLatch(1);
		main.post(() -> {
			try {
				shutDown();
			} finally {
				done.countDown();
			}
		});
		try {
			done.await(1, TimeUnit.SECONDS);
		} catch (InterruptedException interrupted) {
			Thread.currentThread().interrupt();
		}
	}

	/** The end of this bridge's time as the phone's player. Runs on the main thread. */
	private void shutDown() {
		if (session == null) return;
		playing = false;
		active = false;
		pausedByFocus = false;
		stopVolumeWatch();
		abandonFocus();
		PlaybackService.stop();
		notifications.cancel(NOTIFICATION);
		// Released rather than made inactive: the controls must not come back for a session whose
		// app is on its way out. The session is forgotten, so a report still posted does nothing.
		MediaSession closing = session;
		session = null;
		closing.setActive(false);
		closing.release();
		artPath = null;
		art = null;
		reportedTitle = null;
		reportedArtist = null;
		reportedAlbum = null;
		reportedDuration = 0;
	}

	/**
	 * Takes or gives back audio focus as playback starts and stops. A pause this bridge made itself
	 * because of a transient loss keeps the focus request, so the gain that follows still arrives;
	 * any other pause lets it go.
	 */
	private void applyFocus(boolean plays) {
		if (plays) {
			if (pauseForOtherAudio) {
				requestFocus();
			} else {
				abandonFocus();
			}
		} else if (!pausedByFocus) {
			abandonFocus();
		}
	}

	private void requestFocus() {
		if (audio == null || focusHeld || !pauseForOtherAudio) return;
		int result;
		if (Build.VERSION.SDK_INT >= 26 && focusRequest != null) {
			result = audio.requestAudioFocus(focusRequest);
		} else {
			result = audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
		}
		focusHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
	}

	private void abandonFocus() {
		if (audio == null || !focusHeld) return;
		if (Build.VERSION.SDK_INT >= 26 && focusRequest != null) {
			audio.abandonAudioFocusRequest(focusRequest);
		} else {
			audio.abandonAudioFocus(focusListener);
		}
		focusHeld = false;
	}

	/** What the system says about focus. The queue carries it to Lua, which owns playback. */
	private void onFocusChange(int change) {
		if (!pauseForOtherAudio) return;
		switch (change) {
			case AudioManager.AUDIOFOCUS_LOSS:
				// Gone for good: pause and do not ask again until the listener starts playback.
				focusHeld = false;
				pausedByFocus = false;
				if (playing) commands.add(FOCUS_LOSS);
				break;
			case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
				// A call, navigation or a notification: pause, but hold the focus request so the
				// gain that follows can resume it.
				if (playing) {
					pausedByFocus = true;
					commands.add(FOCUS_PAUSE);
				}
				break;
			case AudioManager.AUDIOFOCUS_GAIN:
				if (pausedByFocus) {
					pausedByFocus = false;
					commands.add(FOCUS_RESUME);
				}
				break;
			default:
				// AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK: the system lowers this stream itself on API
				// 26 and later, so nothing here changes the volume. Before 26 it keeps playing.
				break;
		}
	}

	private void startVolumeWatch() {
		if (watchingVolume || audio == null || context == null) return;
		watchingVolume = true;
		// Starting at zero is not a fall to zero: only a drop while playing pauses.
		lastVolume = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
		// VOLUME_CHANGED_ACTION is a hidden platform constant, so it is spelled out here rather
		// than named; android.jar has no symbol for it.
		IntentFilter filter = new IntentFilter("android.media.VOLUME_CHANGED_ACTION");
		if (Build.VERSION.SDK_INT >= 33) {
			// VOLUME_CHANGED_ACTION is a system broadcast, which NOT_EXPORTED would not deliver.
			context.registerReceiver(volumeReceiver, filter, Context.RECEIVER_EXPORTED);
		} else {
			context.registerReceiver(volumeReceiver, filter);
		}
	}

	private void stopVolumeWatch() {
		if (!watchingVolume) return;
		watchingVolume = false;
		try {
			context.unregisterReceiver(volumeReceiver);
		} catch (IllegalArgumentException alreadyGone) {
			// Not registered any more; nothing to take down.
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
