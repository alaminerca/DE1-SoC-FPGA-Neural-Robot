// de1soc_data_collect_v2.ino — 3 fixed sensors, no servo
// Drives the robot using FPGA inference while logging all data.
// Output: CSV over Serial Monitor — copy/paste to save.
//
// Wiring:
//   A0 = Shared TRIG (all 3 HC-SR04)
//   A1 = Left ECHO
//   A2 = Center ECHO
//   A3 = Right ECHO
//   A4 = SoftwareSerial TX -> FPGA
//   A5 = SoftwareSerial RX <- FPGA
//   D2-D13 = Motors

#include <SoftwareSerial.h>

// === PINS ===
#define TRIG_PIN    A0
#define ECHO_LEFT   A1
#define ECHO_CENTER A2
#define ECHO_RIGHT  A3

// Motor pins (Timer2 fix applied)
#define L1_ENA 5
#define L1_ENB 6
#define L1_IN1 4
#define L1_IN2 7
#define L1_IN3 8
#define L1_IN4 12
#define L2_ENA 11
#define L2_ENB 3
#define L2_IN1 9
#define L2_IN2 13
#define L2_IN3 10
#define L2_IN4 2

// === OBJECTS ===
SoftwareSerial fpgaSerial(A5, A4);

// === TUNING ===
#define MOTOR_SPEED  100   // Slow for data collection
#define TURN_TIME    350
#define SENSOR_DELAY 30

// Track state
int currentAction = -1;

// --- Ultrasonic distance (cm) ---
long readDistanceCm(int echoPin) {
    digitalWrite(TRIG_PIN, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);

    long duration = pulseIn(echoPin, HIGH, 25000);
    if (duration == 0) return 400;
    return duration / 58;
}

uint8_t distToByte(long cm) {
    if (cm > 400) cm = 400;
    if (cm < 0) cm = 0;
    return (uint8_t)map(cm, 0, 400, 0, 255);
}

// --- Motor control ---
void setMotors(bool leftFwd, bool rightFwd, int speed) {
    digitalWrite(L1_IN1, leftFwd ? HIGH : LOW);
    digitalWrite(L1_IN2, leftFwd ? LOW : HIGH);
    digitalWrite(L1_IN3, leftFwd ? HIGH : LOW);
    digitalWrite(L1_IN4, leftFwd ? LOW : HIGH);
    analogWrite(L1_ENA, speed);
    analogWrite(L1_ENB, speed);

    digitalWrite(L2_IN1, rightFwd ? HIGH : LOW);
    digitalWrite(L2_IN2, rightFwd ? LOW : HIGH);
    digitalWrite(L2_IN3, rightFwd ? HIGH : LOW);
    digitalWrite(L2_IN4, rightFwd ? LOW : HIGH);
    analogWrite(L2_ENA, speed);
    analogWrite(L2_ENB, speed);
}

void goForward()  { setMotors(true,  true,  MOTOR_SPEED); }
void goSlow()     { setMotors(true,  true,  MOTOR_SPEED / 2); }
void stopMotors() { setMotors(true,  true,  0); }
void turnLeft()   { setMotors(false, true,  MOTOR_SPEED); }
void turnRight()  { setMotors(true,  false, MOTOR_SPEED); }

void setup() {
    Serial.begin(9600);
    fpgaSerial.begin(9600);

    pinMode(TRIG_PIN, OUTPUT);
    pinMode(ECHO_LEFT, INPUT);
    pinMode(ECHO_CENTER, INPUT);
    pinMode(ECHO_RIGHT, INPUT);

    int motorPins[] = {L1_ENA, L1_ENB, L1_IN1, L1_IN2, L1_IN3, L1_IN4,
                       L2_ENA, L2_ENB, L2_IN1, L2_IN2, L2_IN3, L2_IN4};
    for (int i = 0; i < 12; i++) pinMode(motorPins[i], OUTPUT);

    stopMotors();

    Serial.println("=== DATA COLLECTION v2 (3 fixed sensors) ===");
    Serial.println("Speed: 100/255");
    Serial.println("Flip SW[0] on FPGA. Starting in 3s...");
    delay(3000);

    // CSV header
    Serial.println("dist_left,dist_center,dist_right,byte_left,byte_center,byte_right,fpga_class");
}

void loop() {
    // --- Read 3 sensors ---
    long distLeft   = readDistanceCm(ECHO_LEFT);
    delay(SENSOR_DELAY);
    long distCenter = readDistanceCm(ECHO_CENTER);
    delay(SENSOR_DELAY);
    long distRight  = readDistanceCm(ECHO_RIGHT);
    delay(SENSOR_DELAY);

    // --- Send to FPGA ---
    uint8_t byteLeft   = distToByte(distLeft);
    uint8_t byteCenter = distToByte(distCenter);
    uint8_t byteRight  = distToByte(distRight);

    fpgaSerial.write(byteLeft);
    fpgaSerial.write(byteCenter);
    fpgaSerial.write(byteRight);

    // --- Read FPGA class ---
    unsigned long startTime = millis();
    int fpgaClass = -1;
    while (millis() - startTime < 100) {
        if (fpgaSerial.available()) {
            fpgaClass = fpgaSerial.read() & 0x03;
            break;
        }
    }

    // --- Log CSV ---
    Serial.print(distLeft);   Serial.print(",");
    Serial.print(distCenter); Serial.print(",");
    Serial.print(distRight);  Serial.print(",");
    Serial.print(byteLeft);   Serial.print(",");
    Serial.print(byteCenter); Serial.print(",");
    Serial.print(byteRight);  Serial.print(",");
    Serial.println(fpgaClass);

    // --- Execute (drive while collecting) ---
    if (fpgaClass == 0) {
        if (distCenter < 50) {
            goSlow();
        } else {
            goForward();
        }
    } else if (fpgaClass == 1) {
        stopMotors();
    } else if (fpgaClass == 2) {
        if (distLeft > distRight) {
            turnLeft();
        } else {
            turnRight();
        }
        delay(TURN_TIME);
        stopMotors();
    } else {
        stopMotors();
    }
}
