package com.signalrelay.app;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.FloatBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import ai.onnxruntime.TensorInfo;

public class MainActivity extends Activity {
    private static final int REQ_PERMS = 1001;
    private static final int REQ_FILE = 1002;
    private WebView webView;
    private ValueCallback<Uri[]> fileCallback;
    private NativeAI nativeAI;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        webView = new WebView(this);
        webView.setBackgroundColor(0xFF06101A);
        setContentView(webView);
        nativeAI = new NativeAI(this);
        configureWebView();
        requestRuntimePermissions();
        webView.loadUrl("file:///android_asset/www/index.html");
    }

    private void configureWebView() {
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true); s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true); s.setAllowContentAccess(true); s.setMediaPlaybackRequiresUserGesture(false);
        s.setBuiltInZoomControls(false); s.setDisplayZoomControls(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setAllowFileAccessFromFileURLs(false); s.setAllowUniversalAccessFromFileURLs(false);
        webView.addJavascriptInterface(nativeAI, "NativeAI");
        webView.setWebViewClient(new WebViewClient());
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) {
                boolean fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
                boolean coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
                callback.invoke(origin, fine || coarse, false);
            }
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> {
                    List<String> allowed = new ArrayList<>();
                    for (String r : request.getResources()) if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r) && checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) allowed.add(r);
                    if (allowed.isEmpty()) request.deny(); else request.grant(allowed.toArray(new String[0]));
                });
            }
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null); fileCallback = cb;
                Intent intent = params.createIntent();
                try { startActivityForResult(intent, REQ_FILE); return true; }
                catch (Exception e) { fileCallback = null; Toast.makeText(MainActivity.this, "파일 선택기를 열 수 없습니다.", Toast.LENGTH_SHORT).show(); return false; }
            }
        });
    }

    private void requestRuntimePermissions() {
        List<String> req = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) req.add(Manifest.permission.CAMERA);
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) req.add(Manifest.permission.ACCESS_FINE_LOCATION);
        if (!req.isEmpty()) requestPermissions(req.toArray(new String[0]), REQ_PERMS);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_FILE && fileCallback != null) {
            Uri[] result = null;
            if (resultCode == RESULT_OK && data != null && data.getData() != null) result = new Uri[]{data.getData()};
            fileCallback.onReceiveValue(result); fileCallback = null;
        }
    }
    @Override protected void onDestroy() { if (nativeAI != null) nativeAI.close(); if (webView != null) webView.destroy(); super.onDestroy(); }
    @Override public void onBackPressed() { if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed(); }

    public static class NativeAI {
        private final Context context; private final OrtEnvironment env; private OrtSession session; private String provider = "CPU";
        private static final int SIZE = 640; private final File modelFile;
        NativeAI(Context context) { this.context = context; this.env = OrtEnvironment.getEnvironment(); this.modelFile = new File(context.getFilesDir(), "signal_detector.onnx"); if (modelFile.exists()) loadSession(); }
        @JavascriptInterface public synchronized boolean isModelInstalled() { return modelFile.exists(); }
        @JavascriptInterface public synchronized String getRuntimeInfo() {
            try { JSONObject o = new JSONObject(); o.put("installed", modelFile.exists()); o.put("loaded", session != null); o.put("provider", provider); o.put("runtime", "ONNX Runtime Android Native"); return o.toString(); } catch (Exception e) { return "{}"; }
        }
        @JavascriptInterface public synchronized String installModel(String dataUrl) {
            try { int comma = dataUrl.indexOf(','); String b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl; byte[] bytes = Base64.decode(b64, Base64.DEFAULT); try (FileOutputStream fos = new FileOutputStream(modelFile)) { fos.write(bytes); } loadSession(); return ok("모델 설치 완료"); } catch (Throwable t) { return error(t); }
        }
        @JavascriptInterface public synchronized String removeModel() {
            try { if (session != null) { session.close(); session = null; } boolean deleted = !modelFile.exists() || modelFile.delete(); JSONObject o = new JSONObject(); o.put("ok", deleted); o.put("message", deleted ? "모델 삭제 완료" : "모델 삭제 실패"); return o.toString(); } catch (Throwable t) { return error(t); }
        }
        private synchronized void loadSession() {
            if (!modelFile.exists()) return;
            try {
                if (session != null) { session.close(); session = null; }
                OrtSession.SessionOptions so = new OrtSession.SessionOptions(); so.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
                try { so.addNnapi(); session = env.createSession(modelFile.getAbsolutePath(), so); provider = "NNAPI"; }
                catch (Throwable nnapiFail) { try { so.close(); } catch (Throwable ignored) {} so = new OrtSession.SessionOptions(); so.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT); so.setIntraOpNumThreads(Math.max(1, Runtime.getRuntime().availableProcessors() / 2)); session = env.createSession(modelFile.getAbsolutePath(), so); provider = "CPU"; }
            } catch (Throwable t) { session = null; provider = "LOAD_FAILED"; }
        }
        @JavascriptInterface public synchronized String analyze(String imageDataUrl, String classCsv, double conf, double iouThr) {
            long start = System.nanoTime();
            try {
                if (session == null) loadSession(); if (session == null) throw new IllegalStateException("설치된 ONNX 모델을 로드할 수 없습니다.");
                String[] classes = Arrays.stream(classCsv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toArray(String[]::new); if (classes.length == 0) throw new IllegalArgumentException("클래스 이름이 비어 있습니다.");
                Bitmap original = decodeDataUrl(imageDataUrl); if (original == null) throw new IllegalArgumentException("사진을 읽지 못했습니다."); Preprocessed pp = preprocess(original);
                String inputName = session.getInputNames().iterator().next(); long[] shape = new long[]{1, 3, SIZE, SIZE};
                try (OnnxTensor tensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(pp.chw), shape)) {
                    Map<String, OnnxTensor> inputs = new HashMap<>(); inputs.put(inputName, tensor);
                    try (OrtSession.Result result = session.run(inputs)) {
                        OnnxTensor out = (OnnxTensor) result.get(0); TensorInfo info = (TensorInfo) out.getInfo(); long[] dims = info.getShape(); FloatBuffer fb = out.getFloatBuffer(); float[] raw = new float[fb.remaining()]; fb.get(raw);
                        List<Det> dets = parseYolo(raw, dims, classes, (float)conf, (float)iouThr, pp); JSONObject response = new JSONObject(); response.put("ok", true); response.put("provider", provider); response.put("elapsedMs", (System.nanoTime()-start)/1_000_000.0); JSONArray arr = new JSONArray();
                        for (Det d : dets) { JSONObject j = new JSONObject(); j.put("label", d.label); j.put("score", d.score); j.put("x1", d.x1); j.put("y1", d.y1); j.put("x2", d.x2); j.put("y2", d.y2); arr.put(j); }
                        response.put("detections", arr); return response.toString();
                    }
                }
            } catch (Throwable t) { return error(t); }
        }
        private Bitmap decodeDataUrl(String dataUrl) { int comma = dataUrl.indexOf(','); String b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl; byte[] bytes = Base64.decode(b64, Base64.DEFAULT); return BitmapFactory.decodeByteArray(bytes, 0, bytes.length); }
        private Preprocessed preprocess(Bitmap src) {
            int ow = src.getWidth(), oh = src.getHeight(); float scale = Math.min((float)SIZE/ow, (float)SIZE/oh); int nw = Math.max(1, Math.round(ow*scale)), nh = Math.max(1, Math.round(oh*scale)); int dx=(SIZE-nw)/2, dy=(SIZE-nh)/2;
            Bitmap resized = Bitmap.createScaledBitmap(src, nw, nh, true); Bitmap canvas = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888); android.graphics.Canvas c = new android.graphics.Canvas(canvas); c.drawColor(android.graphics.Color.BLACK); c.drawBitmap(resized, dx, dy, null);
            int[] px = new int[SIZE*SIZE]; canvas.getPixels(px,0,SIZE,0,0,SIZE,SIZE); float[] chw = new float[3*SIZE*SIZE]; int plane=SIZE*SIZE;
            for(int i=0;i<px.length;i++){ int p=px[i]; chw[i]=((p>>16)&255)/255f; chw[plane+i]=((p>>8)&255)/255f; chw[2*plane+i]=(p&255)/255f; }
            return new Preprocessed(chw,ow,oh,scale,dx,dy);
        }
        private List<Det> parseYolo(float[] raw,long[] dims,String[] classes,float conf,float iouThr,Preprocessed pp){
            if(dims.length!=3) throw new IllegalArgumentException("지원하지 않는 출력 차원: "+Arrays.toString(dims)); int a=(int)dims[1], b=(int)dims[2]; boolean cFirst=a<b; int channels=cFirst?a:b, count=cFirst?b:a; int classCount=Math.min(classes.length,channels-4); if(classCount<=0) throw new IllegalArgumentException("모델 출력과 클래스 수가 맞지 않습니다."); List<Det> boxes=new ArrayList<>();
            for(int n=0;n<count;n++){ int best=-1; float score=0f; for(int c=0;c<classCount;c++){ float s=get(raw,cFirst,channels,count,4+c,n); if(s>score){score=s;best=c;} } if(best<0||score<conf) continue; float cx=get(raw,cFirst,channels,count,0,n), cy=get(raw,cFirst,channels,count,1,n), w=get(raw,cFirst,channels,count,2,n), h=get(raw,cFirst,channels,count,3,n); float x1=(cx-w/2-pp.dx)/pp.scale, y1=(cy-h/2-pp.dy)/pp.scale, x2=(cx+w/2-pp.dx)/pp.scale, y2=(cy+h/2-pp.dy)/pp.scale; boxes.add(new Det(best,classes[best],score,clamp(x1,0,pp.ow),clamp(y1,0,pp.oh),clamp(x2,0,pp.ow),clamp(y2,0,pp.oh))); }
            boxes.sort((x,y)->Float.compare(y.score,x.score)); List<Det> keep=new ArrayList<>(); for(Det d:boxes){ boolean suppressed=false; for(Det k:keep) if(k.cls==d.cls && iou(d,k)>iouThr){suppressed=true;break;} if(!suppressed){keep.add(d);if(keep.size()>=30)break;} } return keep;
        }
        private float get(float[] raw,boolean cFirst,int channels,int count,int c,int n){ return cFirst ? raw[c*count+n] : raw[n*channels+c]; }
        private float clamp(float v,float lo,float hi){return Math.max(lo,Math.min(hi,v));}
        private float iou(Det a,Det b){ float x1=Math.max(a.x1,b.x1),y1=Math.max(a.y1,b.y1),x2=Math.min(a.x2,b.x2),y2=Math.min(a.y2,b.y2); float inter=Math.max(0,x2-x1)*Math.max(0,y2-y1); float aa=Math.max(0,a.x2-a.x1)*Math.max(0,a.y2-a.y1),bb=Math.max(0,b.x2-b.x1)*Math.max(0,b.y2-b.y1); return inter/(aa+bb-inter+1e-9f); }
        private String ok(String message){ try{JSONObject o=new JSONObject();o.put("ok",true);o.put("message",message);o.put("provider",provider);return o.toString();} catch(Exception e){return "{\"ok\":true}";} }
        private String error(Throwable t){ try{JSONObject o=new JSONObject();o.put("ok",false);o.put("error",String.valueOf(t.getMessage()));return o.toString();} catch(Exception e){return "{\"ok\":false}";} }
        synchronized void close(){try{if(session!=null)session.close();}catch(Throwable ignored){} }
        static class Preprocessed { float[] chw; int ow,oh; float scale; int dx,dy; Preprocessed(float[] c,int ow,int oh,float s,int dx,int dy){this.chw=c;this.ow=ow;this.oh=oh;this.scale=s;this.dx=dx;this.dy=dy;} }
        static class Det { int cls; String label; float score,x1,y1,x2,y2; Det(int c,String l,float s,float a,float b,float x,float y){cls=c;label=l;score=s;x1=a;y1=b;x2=x;y2=y;} }
    }
}
