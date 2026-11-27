package android.print;

import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.webkit.WebView;

import java.io.File;

/**
 * Prints an Android WebView directly to a vector-text ISO A4 (21 x 29.7 cm) PDF file
 * using Chromium's built-in PrintDocumentAdapter without displaying the system print UI.
 */
public final class WebViewPdfPrinter {
    public interface Callback {
        void onComplete(boolean success, String error);
    }

    private WebViewPdfPrinter() {}

    public static void printToPdf(final WebView webView, final File outFile, final Callback callback) {
        try {
            if (outFile.getParentFile() != null && !outFile.getParentFile().exists()) {
                outFile.getParentFile().mkdirs();
            }
            final PrintAttributes attrs = new PrintAttributes.Builder()
                    .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                    .setResolution(new PrintAttributes.Resolution("eri_pdf", "PDF", 300, 300))
                    .setColorMode(PrintAttributes.COLOR_MODE_COLOR)
                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                    .build();

            final PrintDocumentAdapter adapter = webView.createPrintDocumentAdapter("ERI_Export");
            adapter.onStart();
            adapter.onLayout(null, attrs, new CancellationSignal(), new PrintDocumentAdapter.LayoutResultCallback() {
                @Override
                public void onLayoutFinished(PrintDocumentInfo info, boolean changed) {
                    try {
                        final ParcelFileDescriptor pfd = ParcelFileDescriptor.open(
                                outFile,
                                ParcelFileDescriptor.MODE_CREATE
                                        | ParcelFileDescriptor.MODE_TRUNCATE
                                        | ParcelFileDescriptor.MODE_WRITE_ONLY
                        );
                        adapter.onWrite(
                                new PageRange[]{PageRange.ALL_PAGES},
                                pfd,
                                new CancellationSignal(),
                                new PrintDocumentAdapter.WriteResultCallback() {
                                    @Override
                                    public void onWriteFinished(PageRange[] pages) {
                                        try { pfd.close(); } catch (Throwable ignored) {}
                                        try { adapter.onFinish(); } catch (Throwable ignored) {}
                                        callback.onComplete(outFile.exists() && outFile.length() > 512L, null);
                                    }

                                    @Override
                                    public void onWriteFailed(CharSequence error) {
                                        try { pfd.close(); } catch (Throwable ignored) {}
                                        try { adapter.onFinish(); } catch (Throwable ignored) {}
                                        callback.onComplete(false, error != null ? error.toString() : "write_failed");
                                    }

                                    @Override
                                    public void onWriteCancelled() {
                                        try { pfd.close(); } catch (Throwable ignored) {}
                                        try { adapter.onFinish(); } catch (Throwable ignored) {}
                                        callback.onComplete(false, "write_cancelled");
                                    }
                                }
                        );
                    } catch (Throwable t) {
                        try { adapter.onFinish(); } catch (Throwable ignored) {}
                        callback.onComplete(false, t.getMessage());
                    }
                }

                @Override
                public void onLayoutFailed(CharSequence error) {
                    try { adapter.onFinish(); } catch (Throwable ignored) {}
                    callback.onComplete(false, error != null ? error.toString() : "layout_failed");
                }

                @Override
                public void onLayoutCancelled() {
                    try { adapter.onFinish(); } catch (Throwable ignored) {}
                    callback.onComplete(false, "layout_cancelled");
                }
            }, null);
        } catch (Throwable t) {
            callback.onComplete(false, t.getMessage());
        }
    }
}
