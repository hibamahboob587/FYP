#include "esp_camera.h"

// protocol
#define START1 0xAA
#define START2 0x55
#define END1   0x55
#define END2   0xAA

// reliability
#define MAX_IMAGE_SIZE 60000
#define CAPTURE_COOLDOWN 3000

unsigned long lastCapture = 0;

void initCamera() {
  camera_config_t config;

  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;

  config.pin_d0  = 5;
  config.pin_d1  = 18;
  config.pin_d2  = 19;
  config.pin_d3  = 21;
  config.pin_d4  = 36;
  config.pin_d5  = 39;
  config.pin_d6  = 34;
  config.pin_d7  = 35;

  config.pin_xclk     = 0;
  config.pin_pclk     = 22;
  config.pin_vsync    = 25;
  config.pin_href     = 23;

  config.pin_sscb_sda = 26;
  config.pin_sscb_scl = 27;

  config.pin_pwdn  = 32;
  config.pin_reset = -1;

  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count     = 1;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    while (true) { delay(1000); }
  }
}

void sendImage() {
  if (millis() - lastCapture < CAPTURE_COOLDOWN) return;

  lastCapture = millis();

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.write('E');  // tells main ESP32 capture failed
    return;
  }

  if (fb->len > MAX_IMAGE_SIZE) {
    esp_camera_fb_return(fb);
    return;
  }

  // ACK
  Serial.write('K');
  delay(20);

  // start marker
  Serial.write(START1);
  Serial.write(START2);

  // size
  uint32_t sz = fb->len;
  Serial.write((uint8_t*)&sz, sizeof(sz));

  delay(50);

  // chunks
  for (size_t i = 0; i < fb->len; i += 256) {
    size_t chunk = min((size_t)256, fb->len - i);
    Serial.write(fb->buf + i, chunk);
    delay(8);
  }

  // end marker
  Serial.write(END1);
  Serial.write(END2);

  esp_camera_fb_return(fb);
}

void setup() {
  // 9600 matches main ESP32 — no debug output, Serial is the data channel
  Serial.begin(115200);
  initCamera();
}

void loop() {
  if (Serial.available()) {
    char cmd = Serial.read();
    if (cmd == 'C') {
      sendImage();
    }
  }
}
