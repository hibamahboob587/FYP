#include "esp_camera.h"
#include <WiFi.h>
#include <HTTPClient.h>

// ---- CHANGE THESE ----
const char* ssid     = "Jazz-LTE-4969";
const char* password = "55233965";
const char* testURL  = "http://192.168.1.100:9999/test-image";
// ----------------------

#define FLASH_LED 4

void blinkN(int n) {
  for (int i = 0; i < n; i++) {
    digitalWrite(FLASH_LED, HIGH); delay(300);
    digitalWrite(FLASH_LED, LOW);  delay(300);
  }
  delay(800);
}

bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0  = 5;  config.pin_d1  = 18;
  config.pin_d2  = 19; config.pin_d3  = 21;
  config.pin_d4  = 36; config.pin_d5  = 39;
  config.pin_d6  = 34; config.pin_d7  = 35;
  config.pin_xclk     = 0;
  config.pin_pclk     = 22;
  config.pin_vsync    = 25;
  config.pin_href     = 23;
  config.pin_sscb_sda = 26;
  config.pin_sscb_scl = 27;
  config.pin_pwdn     = 32;
  config.pin_reset    = -1;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count     = 1;
  return esp_camera_init(&config) == ESP_OK;
}

void setup() {
  Serial.begin(115200);
  pinMode(FLASH_LED, OUTPUT);
  digitalWrite(FLASH_LED, LOW);

  Serial.println("\n[TEST] ESP32-CAM WiFi Image Test");

  // 1) Camera init
  Serial.println("[1] Initializing camera...");
  if (!initCamera()) {
    Serial.println("[FAIL] Camera init failed — hardware likely damaged");
    while (true) { blinkN(1); }  // 1 blink = init failed
  }
  Serial.println("[OK] Camera initialized");
  blinkN(2);  // 2 blinks = init ok

  // 2) Capture
  Serial.println("[2] Capturing image...");
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[FAIL] Capture failed — power issue");
    while (true) { blinkN(3); }  // 3 blinks = capture failed
  }
  Serial.printf("[OK] Captured %u bytes | JPEG: %s\n",
    fb->len,
    (fb->buf[0] == 0xFF && fb->buf[1] == 0xD8) ? "valid" : "INVALID"
  );
  blinkN(4);  // 4 blinks = capture ok

  // 3) WiFi
  Serial.printf("[3] Connecting to %s...\n", ssid);
  WiFi.begin(ssid, password);
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500); Serial.print(".");
    attempts++;
  }
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[FAIL] WiFi failed");
    esp_camera_fb_return(fb);
    while (true) { blinkN(5); }  // 5 blinks = WiFi failed
  }
  Serial.printf("\n[OK] WiFi connected — IP: %s\n", WiFi.localIP().toString().c_str());
  blinkN(6);  // 6 blinks = WiFi ok

  // 4) POST image to test backend
  Serial.printf("[4] POSTing image to %s\n", testURL);
  WiFiClient client;
  HTTPClient http;
  http.begin(client, testURL);
  http.addHeader("Content-Type", "image/jpeg");
  int code = http.POST(fb->buf, fb->len);
  Serial.printf("[HTTP] Response: %d\n", code);
  if (code > 0) Serial.println(http.getString());
  http.end();
  esp_camera_fb_return(fb);

  if (code == 200) {
    // solid LED = full success
    Serial.println("[SUCCESS] Image sent — check backend for saved image");
    digitalWrite(FLASH_LED, HIGH);
  } else {
    Serial.printf("[FAIL] HTTP error: %d\n", code);
    while (true) { blinkN(7); }  // 7 blinks = HTTP failed
  }
}

void loop() {}
