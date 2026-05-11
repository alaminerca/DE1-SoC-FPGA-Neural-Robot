// de1soc_phase5_3sensor.ino — v5b
// 3 fixed HC-SR04 sensors (no servo scan).
// FPGA brain makes ALL decisions. Arduino only reads sensors and executes.
// Backup timer: if no FORWARD for 5 seconds, reverse and turn (stuck recovery).
// Loop time: ~100ms (6-8x faster than servo-scan version).
//
// Wiring:
//   A0 = Shared TRIG (all 3 HC-SR04)
//   A1 = Left HC-SR04 ECHO
//   A2 = Center HC-SR04 ECHO
//   A3 = Right HC-SR04 ECHO
//   A4 = SoftwareSerial TX -> FPGA (via level converter HV1->LV1)
//   A5 = SoftwareSerial RX <- FPGA (via level converter HV2->LV2)
//   D2-D13 = Motor drivers (L298N wiring)
//
// Classes from FPGA: 0=FORWARD, 1=STOP, 2=TURN

#include <SoftwareSerial.h>

// === PINS ===
#define TRIG_PIN   A0
#define ECHO_LEFT  A1
#define ECHO_CENTER A2
#define ECHO_RIGHT A3

// Motor pins (Timer2 fix applied — no servo needed)
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
SoftwareSerial fpgaSerial(A5, A4);  // RX=A5, TX=A4

// === TUNING ===
#define MOTOR_SPEED  120   // PWM duty (demo-safe speed)
#define TURN_TIME    200   // ms to turn before re-reading
#define SENSOR_DELAY 30    // ms between sequential sensor reads
#define STUCK_TIMEOUT 5000 // ms without FORWARD before backup recovery

// Track state
int currentAction = -1;

// Stuck detection: timestamp of last FORWARD command
unsigned long lastForwardTime = 0;

// --- Ultrasonic distance (cm) for a specific echo pin ---
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

// --- Map distance to 0-255 byte ---
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
void reverse()    { setMotors(false, false, MOTOR_SPEED); }

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

    Serial.println("=== DE1-SoC Robot v5b (3-sensor, no override) ===");
    Serial.println("Speed: 120 | Stuck timeout: 5s");
    Serial.println();

    // Motor self-test
    Serial.println("MOTOR TEST:");
    Serial.print("  LF...");
    digitalWrite(L1_IN1, HIGH); digitalWrite(L1_IN2, LOW);
    analogWrite(L1_ENA, 200); delay(400); analogWrite(L1_ENA, 0);
    Serial.println(" ok");

    Serial.print("  LR...");
    digitalWrite(L1_IN3, HIGH); digitalWrite(L1_IN4, LOW);
    analogWrite(L1_ENB, 200); delay(400); analogWrite(L1_ENB, 0);
    Serial.println(" ok");

    Serial.print("  RF...");
    digitalWrite(L2_IN1, HIGH); digitalWrite(L2_IN2, LOW);
    analogWrite(L2_ENA, 200); delay(400); analogWrite(L2_ENA, 0);
    Serial.println(" ok");

    Serial.print("  RR...");
    digitalWrite(L2_IN3, HIGH); digitalWrite(L2_IN4, LOW);
    analogWrite(L2_ENB, 200); delay(400); analogWrite(L2_ENB, 0);
    Serial.println(" ok");

    stopMotors();
    Serial.println("Flip SW[0] on FPGA. Starting in 2s...");
    delay(2000);

    lastForwardTime = millis();
}

void loop() {
    // --- Step 1: Read all 3 sensors ---
    long distLeft   = readDistanceCm(ECHO_LEFT);
    delay(SENSOR_DELAY);
    long distCenter = readDistanceCm(ECHO_CENTER);
    delay(SENSOR_DELAY);
    long distRight  = readDistanceCm(ECHO_RIGHT);
    delay(SENSOR_DELAY);

    // --- Step 2: Send distances to FPGA ---
    uint8_t byteLeft   = distToByte(distLeft);
    uint8_t byteCenter = distToByte(distCenter);
    uint8_t byteRight  = distToByte(distRight);

    fpgaSerial.write(byteLeft);
    fpgaSerial.write(byteCenter);
    fpgaSerial.write(byteRight);

    // --- Step 3: Read class from FPGA ---
    unsigned long startTime = millis();
    int fpgaClass = -1;
    while (millis() - startTime < 100) {
        if (fpgaSerial.available()) {
            fpgaClass = fpgaSerial.read() & 0x03;
            break;
        }
    }

    // --- Step 4: Debug print ---
    Serial.print("L="); Serial.print(distLeft);
    Serial.print(" C="); Serial.print(distCenter);
    Serial.print(" R="); Serial.print(distRight);
    Serial.print(" ["); Serial.print(byteLeft);
    Serial.print(","); Serial.print(byteCenter);
    Serial.print(","); Serial.print(byteRight);
    Serial.print("] Cls="); Serial.println(fpgaClass);

    // --- Step 5: Check stuck timeout ---
    if (millis() - lastForwardTime > STUCK_TIMEOUT) {
        Serial.println("  !! STUCK 5s — backup recovery");
        reverse();
        delay(400);
        if (distLeft > distRight) {
            Serial.println("  !! Recovery: LEFT");
            turnLeft();
        } else {
            Serial.println("  !! Recovery: RIGHT");
            turnRight();
        }
        delay(500);
        stopMotors();
        lastForwardTime = millis();
        return;
    }

    // --- Step 6: Execute FPGA command (no Arduino override) ---
    if (fpgaClass < 0) {
        stopMotors();
        Serial.println("  !! NO FPGA — STOPPED");

    } else if (fpgaClass == 0) {
        // FORWARD — slow down when approaching
        lastForwardTime = millis();
        if (distCenter < 50) {
            goSlow();
            Serial.println("  >> FWD (slow)");
        } else {
            goForward();
            Serial.println("  >> FWD");
        }
        currentAction = 0;

    } else if (fpgaClass == 1) {
        // STOP — truly cornered
        stopMotors();
        Serial.println("  [] STOP");
        currentAction = 1;

    } else if (fpgaClass == 2) {
        // TURN — FPGA decided, choose direction by sensor
        if (distLeft > distRight) {
            Serial.println("  <- TURN LEFT");
            turnLeft();
        } else {
            Serial.println("  -> TURN RIGHT");
            turnRight();
        }
        delay(TURN_TIME);
        stopMotors();
        currentAction = 2;
    }
}
