#!/bin/sh
# Rebuilds src/assets/media.dex from android/beat/*.java. The dex is committed: a NativeActivity
# APK has no Java build step, and beat loads this one at run time (see services/system/media.lua).
# Needs a JDK (javac) and the Android SDK: ANDROID_HOME with platforms;android-35 and
# build-tools;35.0.0.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sdk=${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}
jar="$sdk/platforms/android-35/android.jar"
d8="$sdk/build-tools/35.0.0/d8"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

${JAVAC:-javac} --release 11 -classpath "$jar" -d "$out/classes" "$here"/beat/*.java
"$d8" --release --min-api 24 --lib "$jar" --output "$out" $(find "$out/classes" -name '*.class')
mkdir -p "$here/../src/assets"
cp "$out/classes.dex" "$here/../src/assets/media.dex"
