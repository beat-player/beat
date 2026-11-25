package beat;

import android.app.Activity;
import android.os.Build;
import android.view.View;
import android.view.WindowInsetsController;
import java.util.function.Consumer;

/**
 * The clock, battery and gesture handle Android draws over the app, in the colour of the page
 * behind them.
 *
 * Android keeps its system-bar icons white unless an app asks otherwise, so a light theme would
 * put white icons on a light background. Lua has to reach this class through an interface the
 * framework's own class loader can find -- it cannot look a class up in the app's dex by name --
 * and the appearance is a boolean an IntSupplier cannot take. So this class is a Consumer: Lua
 * sends the activity once to attach it, then 1 for dark icons over a light page and 0 for light
 * icons over a dark one. Every change is posted to the UI thread, where the window belongs.
 */
public final class SystemBars implements Consumer<Object> {
	/** The two bars beat draws under, and nothing else of the system's appearance. */
	private static final int LIGHT_BARS =
		WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
			| WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
	/** View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR, for Android before 11. */
	private static final int LEGACY_STATUS_BAR = 0x00002000;
	/** View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR, for Android 8 through 10. */
	private static final int LEGACY_NAVIGATION_BAR = 0x00000010;

	private Activity activity;

	public SystemBars() {
	}

	@Override
	@SuppressWarnings("deprecation")
	public void accept(Object value) {
		if (value instanceof Activity) {
			activity = (Activity) value;
			return;
		}
		if (!(value instanceof Number) || activity == null) return;

		final boolean dark = ((Number) value).intValue() != 0;
		activity.runOnUiThread(() -> apply(dark));
	}

	@SuppressWarnings("deprecation")
	private void apply(boolean dark) {
		if (activity.getWindow() == null) return;
		View decor = activity.getWindow().getDecorView();
		if (decor == null) return;

		if (Build.VERSION.SDK_INT >= 30) {
			Modern.apply(decor, dark);
			return;
		}
		legacy(decor, dark);
	}

	/** Android 11 and later's window controller, kept apart so older Android never loads it. */
	private static final class Modern {
		@SuppressWarnings("deprecation")
		static void apply(View decor, boolean dark) {
			WindowInsetsController controller = decor.getWindowInsetsController();
			if (controller == null) {
				legacy(decor, dark);
				return;
			}
			controller.setSystemBarsAppearance(dark ? LIGHT_BARS : 0, LIGHT_BARS);
		}
	}

	/**
	 * The flags Android used before 11. The navigation flag arrived in Android 8, so the status
	 * bar flag is always set; the others the window already had are left alone.
	 */
	@SuppressWarnings("deprecation")
	private static void legacy(View decor, boolean dark) {
		int flags = decor.getSystemUiVisibility();
		flags &= ~(LEGACY_STATUS_BAR | LEGACY_NAVIGATION_BAR);
		if (dark) flags |= LEGACY_STATUS_BAR;
		if (dark && Build.VERSION.SDK_INT >= 26) flags |= LEGACY_NAVIGATION_BAR;
		decor.setSystemUiVisibility(flags);
	}
}
