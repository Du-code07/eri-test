# 이리ERI R8 / DEX 코드 최적화 및 난독화 규칙
# Play Console "DEX 코드 최적화가 기준점 미만입니다 (난독화)" 해결용

# 스택 트레이스 복원용 최소 속성 유지 (AAB에 mapping.txt 자동 포함)
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 앱 핵심 Android 컴포넌트 유지 (Manifest 등록)
-keep class com.dudu.eri.MainActivity { *; }
-keep class com.dudu.eri.DocumentCameraActivity { *; }
-keep class com.dudu.eri.ScanFileProvider { *; }

# WebView JavascriptInterface 보호
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Flutter 엔진 & 플러그인 (InAppWebView / JNI)
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keep class com.github.dart_lang.jni.** { *; }

# OpenCV JNI 네이티브 브리지 보호 (문서 스캔)
-keepclasseswithmembernames,includedescriptorclasses class org.opencv.** {
    native <methods>;
}
-keep class org.opencv.android.OpenCVLoader { *; }
-keep class org.opencv.android.Utils { *; }
-keep class org.opencv.core.** { *; }
-keep class org.opencv.imgproc.** { *; }

# 선택적 의존성 경고 방지 (빌드 실패 방지)
-dontwarn javax.annotation.**
-dontwarn org.jetbrains.annotations.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.j2objc.annotations.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
-dontwarn org.opencv.**
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
