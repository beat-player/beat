package beat;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.CompletionInfo;
import android.view.inputmethod.CorrectionInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.ExtractedText;
import android.view.inputmethod.ExtractedTextRequest;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextAttribute;
import android.widget.FrameLayout;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.function.Consumer;
import java.util.function.Supplier;

/**
 * The editor the on-screen keyboard types into, which is not the one the app draws.
 *
 * A NativeActivity has no text editor of its own: the keyboard is asked for without an
 * InputConnection, its keys come back as key events, and an input method that would glide,
 * suggest or compose has nothing to do that with. So this class adds a one-pixel EditText-like
 * view to the activity, invisible and focused only while a field is, and takes the keyboard from
 * there. The keyboard talks to the connection this view returns; every edit that makes is
 * queued as one command for Lua, which applies it to the field it actually draws.
 *
 * Lua reaches this class through framework interfaces, because it cannot look a class up in the
 * app's dex by name: `Consumer<Object>` takes the activity once and then the commands, and
 * `Supplier<String>` hands back what the keyboard did since the last poll. A command is text
 * because a text edit is text: see `accept` for the three shapes.
 *
 * Every field is a UTF-16 index here, as Java strings are; what Lua is sent is a UTF-8 byte
 * offset and a UTF-8 string, because that is what the field it edits counts in. The mirror of the
 * field's value is kept here, under one lock: the keyboard reads it for suggestions, and Lua
 * pushes the field's value and caret over with `sync` when it changes by any other way.
 */
public final class TextInput implements Consumer<Object>, Supplier<String> {
	/** EditorInfo.IME_ACTION_SEARCH: the keyboard's action key says search. */
	public static final int SEARCH = EditorInfo.IME_ACTION_SEARCH;
	/** EditorInfo.IME_ACTION_DONE: for a field that is not a search. */
	public static final int DONE = EditorInfo.IME_ACTION_DONE;

	private final Object lock = new Object();
	private final ConcurrentLinkedQueue<String> events = new ConcurrentLinkedQueue<>();

	/** The value the keyboard edits, as the field has it: the same text, one encoding over. */
	private final StringBuilder text = new StringBuilder();
	/** Where the caret is in `text`, in UTF-16 units. */
	private int cursor;
	/** The range the keyboard is composing, in UTF-16 units, or -1 for none. */
	private int composingStart = -1;
	private int composingEnd = -1;
	private volatile int imeAction = SEARCH;

	private Activity activity;
	private Field field;

	public TextInput() {
	}

	/** The next thing the keyboard did, or null: `r` ranges, `k` keys, `a` actions and `p` carets. */
	@Override
	public String get() {
		return events.poll();
	}

	/**
	 * Takes the activity once, then the commands Lua sends:
	 *
	 *   "h"                        hide and give the keyboard up
	 *   "c<cursor>:<text>"         the field now holds text, its caret at cursor, both in UTF-8
	 *   "s<action>:<cursor>:<text>" the same, and show the keyboard with that action key
	 *
	 * The activity is set up on the UI thread, and everything that touches a view is posted there;
	 * the mirror is the only state the Lua thread and the keyboard share.
	 */
	@Override
	public void accept(Object value) {
		if (value instanceof Activity) {
			activity = (Activity) value;
			activity.runOnUiThread(this::install);
			return;
		}
		if (!(value instanceof String)) return;

		String command = (String) value;
		if (command.isEmpty()) return;

		char kind = command.charAt(0);
		if (kind == 'h') {
			hide();
			return;
		}

		int first = command.indexOf(':', 1);
		if (first < 0) return;

		if (kind == 'c') {
			int at = number(command, 1, first);
			if (at >= 0) sync(at, command.substring(first + 1));
			return;
		}

		if (kind == 's') {
			int second = command.indexOf(':', first + 1);
			if (second < 0) return;
			int action = number(command, 1, first);
			int at = number(command, first + 1, second);
			if (at < 0) return;
			// What the keyboard did for the last field is not the new field's: a press that
			// moves the focus may leave a commit of the old text behind.
			events.clear();
			sync(at, command.substring(second + 1));
			show(action);
		}
	}

	/** A whole number in `s[from, to)`, or -1 when it does not hold one. */
	private static int number(String s, int from, int to) {
		if (from >= to) return -1;
		int value = 0;
		for (int i = from; i < to; i++) {
			char c = s.charAt(i);
			if (c < '0' || c > '9') return -1;
			value = value * 10 + (c - '0');
			if (value < 0) return -1;
		}
		return value;
	}

	/** The field's value and caret, as Lua has them: the mirror the keyboard reads and edits. */
	private void sync(int cursorByte, String value) {
		synchronized (lock) {
			text.setLength(0);
			text.append(value);
			cursor = utf16ForByte(value, Math.max(cursorByte, 0));
			cursor = clamp(cursor, 0, text.length());
			composingStart = composingEnd = -1;
		}
	}

	private void install() {
		ensureField();
	}

	/** The hidden editor, made on the UI thread the first time it is wanted. */
	private Field ensureField() {
		if (field != null) return field;
		Activity owner = activity;
		if (owner == null) return null;

		ViewGroup content = owner.findViewById(android.R.id.content);
		if (content == null) return null;

		Field editor = new Field(owner);
		FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(1, 1);
		params.gravity = Gravity.TOP | Gravity.START;
		content.addView(editor, params);
		field = editor;
		return editor;
	}

	/** Ask for the keyboard with `action` as its action key. Runs on the UI thread. */
	private void show(final int action) {
		imeAction = action;
		Activity owner = activity;
		if (owner == null) return;

		owner.runOnUiThread(() -> {
			Field editor = ensureField();
			if (editor == null) return;

			boolean fresh = !editor.hasFocus();
			editor.requestFocus();

			InputMethodManager imm = (InputMethodManager) owner.getSystemService(Context.INPUT_METHOD_SERVICE);
			if (imm == null) return;

			// A new field is a new editor: anything the last one had composing belongs to it. One
			// that is already focused is asked for again after the keyboard was put away, and
			// keeping its input state is what keeps what was typed before it in place.
			if (fresh) imm.restartInput(editor);
			imm.showSoftInput(editor, 0);
		});
	}

	/** Let the keyboard go. Runs on the UI thread. */
	private void hide() {
		Activity owner = activity;
		if (owner == null) return;

		owner.runOnUiThread(() -> {
			// What the keyboard did after the field lost the keyboard is not for the next one.
			events.clear();

			Field editor = field;
			if (editor == null) return;

			InputMethodManager imm = (InputMethodManager) owner.getSystemService(Context.INPUT_METHOD_SERVICE);
			if (imm != null) imm.hideSoftInputFromWindow(editor.getWindowToken(), 0);
			editor.clearFocus();

			synchronized (lock) {
				composingStart = composingEnd = -1;
			}
		});
	}

	/**
	 * The invisible view the keyboard edits. It is a text editor to the input method -- a
	 * focusable view whose connections reports plain text -- and nothing else: it draws nothing,
	 * takes no pointer, and its text lives in the mirror above rather than in the view.
	 */
	private final class Field extends View {
		Field(Context context) {
			super(context);
			setFocusable(true);
			setFocusableInTouchMode(true);
			setClickable(false);
			setLongClickable(false);
			setBackgroundColor(Color.TRANSPARENT);
			setAlpha(0f);
		}

		@Override
		public boolean onCheckIsTextEditor() {
			return true;
		}

		@Override
		public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
			// Plain text with suggestions and composing on: glide typing and the suggestion strip
			// are what an input method only offers a field that asks for them. NO_SUGGESTIONS and
			// VISIBLE_PASSWORD are the flags that take them away.
			outAttrs.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_AUTO_CORRECT;
			outAttrs.imeOptions = imeAction | EditorInfo.IME_FLAG_NO_EXTRACT_UI;

			synchronized (lock) {
				outAttrs.initialSelStart = cursor;
				outAttrs.initialSelEnd = cursor;
			}

			return new Connection(this);
		}
	}

	/**
	 * What the input method says it did, as the range of the field's text it did it to.
	 *
	 * The value it reads is the mirror, so suggestions and composing see the field's text; every
	 * edit it makes becomes one queued command: replace bytes [from, to) of the field's value
	 * with `insert`, leave the caret at `cursor`, all in UTF-8. Lua applies exactly that to the
	 * field it draws, which is how a composing word is seen while it is being composed.
	 */
	private final class Connection extends BaseInputConnection {
		Connection(View target) {
			super(target, true);
		}

		@Override
		public CharSequence getTextBeforeCursor(int n, int flags) {
			synchronized (lock) {
				int start = Math.max(0, cursor - Math.max(n, 0));
				return text.substring(start, cursor);
			}
		}

		@Override
		public CharSequence getTextAfterCursor(int n, int flags) {
			synchronized (lock) {
				int end = Math.min(text.length(), cursor + Math.max(n, 0));
				return text.substring(cursor, end);
			}
		}

		@Override
		public CharSequence getSelectedText(int flags) {
			return null;
		}

		@Override
		public int getCursorCapsMode(int reqModes) {
			synchronized (lock) {
				return TextUtils.getCapsMode(text, cursor, reqModes);
			}
		}

		@Override
		public ExtractedText getExtractedText(ExtractedTextRequest request, int flags) {
			// No extract view: the keyboard reads around the caret instead.
			return null;
		}

		@Override
		public boolean commitText(CharSequence value, int newCursorPosition) {
			String insert = value == null ? "" : value.toString();
			synchronized (lock) {
				int start = composingStart >= 0 ? composingStart : cursor;
				int end = composingStart >= 0 ? composingEnd : cursor;
				replaceLocked(start, end, insert, newCursorPosition, false);
			}
			return true;
		}

		@Override
		public boolean setComposingText(CharSequence value, int newCursorPosition) {
			String insert = value == null ? "" : value.toString();
			synchronized (lock) {
				int start = composingStart >= 0 ? composingStart : cursor;
				int end = composingStart >= 0 ? composingEnd : cursor;
				replaceLocked(start, end, insert, newCursorPosition, true);
			}
			return true;
		}

		@Override
		public boolean setComposingRegion(int start, int end) {
			synchronized (lock) {
				int from = clamp(Math.min(start, end), 0, text.length());
				int to = clamp(Math.max(start, end), from, text.length());
				composingStart = from;
				composingEnd = to;
			}
			return true;
		}

		@Override
		public boolean finishComposingText() {
			synchronized (lock) {
				composingStart = composingEnd = -1;
			}
			return true;
		}

		@Override
		public boolean deleteSurroundingText(int beforeLength, int afterLength) {
			synchronized (lock) {
				int start = clamp(cursor - Math.max(beforeLength, 0), 0, text.length());
				int end = clamp(cursor + Math.max(afterLength, 0), 0, text.length());
				if (start < end) replaceLocked(start, end, "", 1, false);
				else composingStart = composingEnd = -1;
			}
			return true;
		}

		@Override
		public boolean deleteSurroundingTextInCodePoints(int beforeLength, int afterLength) {
			synchronized (lock) {
				int start = cursor;
				for (int i = 0; i < beforeLength && start > 0; i++) {
					start -= Character.charCount(Character.codePointBefore(text, start));
				}
				int end = cursor;
				for (int i = 0; i < afterLength && end < text.length(); i++) {
					end += Character.charCount(Character.codePointAt(text, end));
				}
				if (start < end) replaceLocked(start, end, "", 1, false);
				else composingStart = composingEnd = -1;
			}
			return true;
		}

		@Override
		public boolean setSelection(int start, int end) {
			synchronized (lock) {
				cursor = clamp(end, 0, text.length());
				composingStart = composingEnd = -1;
				// The app draws the caret, so it is told where the keyboard put it.
				events.add("p" + utf8Length(text, 0, cursor));
			}
			return true;
		}

		@Override
		public boolean commitCompletion(CompletionInfo completion) {
			if (completion == null || completion.getText() == null) return true;
			return commitText(completion.getText(), 1);
		}

		@Override
		public boolean commitCorrection(CorrectionInfo correction) {
			if (correction == null) return true;
			return commitText(correction.getNewText(), 1);
		}

		/**
		 * Android 11 and later's form of an edit a keyboard makes as a range, used by an input
		 * method replacing a word rather than typing one. It is the same range the base class
		 * would have applied to an editable, applied to the mirror instead.
		 */
		@Override
		public boolean replaceText(int start, int end, CharSequence value, int newCursorPosition, TextAttribute textAttribute) {
			String insert = value == null ? "" : value.toString();
			synchronized (lock) {
				replaceLocked(start, end, insert, newCursorPosition, false);
			}
			return true;
		}

		@Override
		public boolean performEditorAction(int actionCode) {
			// The field is the app's, and what its action key means is the app's: a return.
			events.add("a" + actionCode);
			return true;
		}

		@Override
		public boolean requestCursorUpdates(int cursorUpdateMode) {
			return false;
		}

		@Override
		public boolean sendKeyEvent(KeyEvent event) {
			if (event.getAction() != KeyEvent.ACTION_DOWN) return true;

			int code = event.getKeyCode();
			if (code == KeyEvent.KEYCODE_DEL) {
				synchronized (lock) {
					int start = cursor > 0 ? cursor - Character.charCount(Character.codePointBefore(text, cursor)) : cursor;
					replaceLocked(start, cursor, "", 1, false);
				}
				return true;
			}

			if (code == KeyEvent.KEYCODE_FORWARD_DEL) {
				synchronized (lock) {
					int end = cursor < text.length() ? cursor + Character.charCount(Character.codePointAt(text, cursor)) : cursor;
					replaceLocked(cursor, end, "", 1, false);
				}
				return true;
			}

			if (code == KeyEvent.KEYCODE_ENTER || code == KeyEvent.KEYCODE_NUMPAD_ENTER
				|| code == KeyEvent.KEYCODE_DPAD_CENTER) {
				events.add("kreturn");
				return true;
			}

			int unicode = event.getUnicodeChar();
			if (unicode != 0) {
				String insert = new String(Character.toChars(unicode));
				synchronized (lock) {
					replaceLocked(cursor, cursor, insert, 1, false);
				}
			}
			return true;
		}
	}

	/**
	 * Replace [start, end) of the mirror with `insert`, leaving the caret where the keyboard
	 * asked, and queue that as a range for Lua. Called with `lock` held.
	 */
	private void replaceLocked(int start, int end, String insert, int newCursorPosition, boolean composing) {
		int limit = text.length();
		start = clamp(start, 0, limit);
		end = clamp(end, start, limit);

		int fromByte = utf8Length(text, 0, start);
		int toByte = utf8Length(text, 0, end);

		String before = text.substring(0, start);
		String after = text.substring(end);
		text.setLength(0);
		text.append(before).append(insert).append(after);

		// Android's rule: a position above nought is relative to the end of the text, one at or
		// below it to the start. One is the caret after what was inserted, which is what a
		// keyboard sends for a word.
		int at = newCursorPosition > 0
			? start + insert.length() + newCursorPosition - 1
			: start + newCursorPosition;
		cursor = clamp(at, 0, text.length());

		if (composing) {
			composingStart = start;
			composingEnd = start + insert.length();
		} else {
			composingStart = composingEnd = -1;
		}

		events.add("r" + fromByte + "," + toByte + "," + utf8Length(text, 0, cursor) + ":" + insert);
	}

	private static int clamp(int value, int low, int high) {
		return value < low ? low : value > high ? high : value;
	}

	/** How many UTF-8 bytes `s[start, end)` holds: what Lua counts a value's characters in. */
	private static int utf8Length(CharSequence s, int start, int end) {
		int bytes = 0;
		for (int i = start; i < end; ) {
			int cp = Character.codePointAt(s, i);
			bytes += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
			i += Character.charCount(cp);
		}
		return bytes;
	}

	/** The UTF-16 index `bytes` UTF-8 bytes into `s`, capped at the end of it. */
	private static int utf16ForByte(CharSequence s, int bytes) {
		int at = 0;
		int seen = 0;
		while (at < s.length() && seen < bytes) {
			int cp = Character.codePointAt(s, at);
			int size = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
			if (seen + size > bytes) break;
			seen += size;
			at += Character.charCount(cp);
		}
		return at;
	}
}
