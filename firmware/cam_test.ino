#include "esp_camera.h"

#define FLASH_LED 4

void blinkFast() {
  while (true) {
    digitalWrite(FLASH_LED, HIGH); delay(100);
    digitalWrite(FLASH_LED, LOW);  delay(100);
  }
}

void blinkTwice() {
  digitalWrite(FLASH_LED, HIGH); delay(400);
  digitalWrite(FLASH_LED, LOW);  delay(400);
  digitalWrite(FLASH_LED, HIGH); delay(400);
  digitalWrite(FLASH_LED, LOW);  delay(1200);
}

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
    // camera init failed — rapid blink forever
    blinkFast();
  }
}

void setup() {
  pinMode(FLASH_LED, OUTPUT);
  digitalWrite(FLASH_LED, LOW);

  initCamera();

  // try capture
  camera_fb_t* fb = esp_camera_fb_get();

  if (!fb) {
    // capture failed — 2 blinks repeat forever
    while (true) blinkTwice();
  }

  bool jpegValid = (fb->len > 0 && fb->buf[0] == 0xFF && fb->buf[1] == 0xD8);
  esp_camera_fb_return(fb);

  if (!jpegValid) {
    // corrupt JPEG — 3 rapid blinks repeat
    while (true) {
      for (int i = 0; i < 3; i++) {
        digitalWrite(FLASH_LED, HIGH); delay(150);
        digitalWrite(FLASH_LED, LOW);  delay(150);
      }
      delay(1000);
    }
  }

  // all good — solid ON for 2 seconds then off
  digitalWrite(FLASH_LED, HIGH);
  delay(2000);
  digitalWrite(FLASH_LED, LOW);
}

void loop() {
  // blink slowly to show still alive
  digitalWrite(FLASH_LED, HIGH); delay(200);
  digitalWrite(FLASH_LED, LOW);  delay(2000);
}
