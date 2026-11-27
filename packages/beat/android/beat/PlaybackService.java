package beat;

import android.app.Notification;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * Keeps beat running while it plays. Android freezes an app that has left the screen after a
 * minute or so, and a frozen app cannot feed the audio device; an app with a foreground service of
 * the media-playback type is left alone. The service holds the playback notification MediaBridge
 * builds, and does nothing else: the player itself is in the app's native code.
 *
 * It is started when playback starts and taken out of the foreground when playback pauses, keeping
 * the notification, so a paused app can be frozen and swiped away as usual.
 */
public final class PlaybackService extends Service {
	private static final int NOTIFICATION = 1;

	private static Notification notification;
	private static PlaybackService running;

	/** Shows `shown` as the foreground notification, starting the service if it is not running. */
	static void hold(Context context, Notification shown) {
		notification = shown;
		if (running != null) {
			running.promote();
			return;
		}
		try {
			Intent intent = new Intent(context, PlaybackService.class);
			if (Build.VERSION.SDK_INT >= 26) {
				context.startForegroundService(intent);
			} else {
				context.startService(intent);
			}
		} catch (RuntimeException refused) {
			// Android refuses a foreground service started from the background. The notification
			// is still posted by MediaBridge; the next start from the screen or a control retries.
			notification = null;
		}
	}

	/** Leaves the foreground, keeping the notification on screen, and stops the service. */
	static void release() {
		PlaybackService service = running;
		if (service == null) return;
		if (Build.VERSION.SDK_INT >= 24) {
			service.stopForeground(Service.STOP_FOREGROUND_DETACH);
		} else {
			service.stopForeground(false);
		}
		service.stopSelf();
		// Nothing should keep the last notification, and the album art it holds, in memory.
		notification = null;
	}

	/**
	 * Takes the service out of the foreground and stops it, notification and all: the app is
	 * leaving, so nothing is left for the system to restart. `START_NOT_STICKY` keeps a deliberate
	 * stop from being a crash to come back from.
	 */
	static void stop() {
		PlaybackService service = running;
		notification = null;
		if (service == null) return;
		if (Build.VERSION.SDK_INT >= 24) {
			service.stopForeground(Service.STOP_FOREGROUND_REMOVE);
		} else {
			service.stopForeground(true);
		}
		service.stopSelf();
	}

	@Override
	public void onCreate() {
		super.onCreate();
		running = this;
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		promote();
		return START_NOT_STICKY;
	}

	private void promote() {
		if (notification == null) return;
		if (Build.VERSION.SDK_INT >= 29) {
			startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
		} else {
			startForeground(NOTIFICATION, notification);
		}
	}

	@Override
	public void onDestroy() {
		if (running == this) running = null;
		notification = null;
		super.onDestroy();
	}

	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}
}
