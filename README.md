# DE1-SoC FPGA Neural Network Robot

Autonomous obstacle-avoidance robot with a fully hardware-implemented neural network on the DE1-SoC (Cyclone V 5CSEMA5F31C6). Inference runs in approximately 1 microsecond using Q6.10 fixed-point arithmetic — no software, no CPU involvement during operation.

## Overview

A compact 3-8-3 feedforward neural network is synthesized directly into FPGA fabric. The robot uses three ultrasonic sensors as input and produces motor commands (forward, left, right) with zero collisions during live demonstration. The system is fully battery-powered and untethered.

## Architecture

```
Ultrasonic Sensors (3x HC-SR04)
        |
   Arduino Nano (sensor reading + UART TX)
        |
   UART @ 115200 baud
        |
   DE1-SoC FPGA (neural network inference)
        |
   Motor Driver (L298N) → DC Motors
```

## Key Specs

| Metric | Value |
|--------|-------|
| Network topology | 3 → 8 → 3 |
| Arithmetic | Q6.10 fixed-point |
| Inference latency | ~1 microsecond |
| FPGA resource usage | 222 ALMs |
| Collisions during demo | 0 |
| Power | Battery (untethered) |

## Project Structure

```
verilog/
  nn_top.v              -- Top-level neural network module
  neuron.v              -- Single neuron with MAC + activation
  uart_rx.v             -- UART receiver
  motor_controller.v    -- Motor output logic
  de1soc_top.v          -- Board-level wrapper

arduino/
  de1soc_data_collect_v2.ino  -- Data collection from sensors

training/
  fpga_nn_v5.ipynb      -- Full training pipeline (Python/PyTorch)
```

## How It Works

1. **Sensing** — Arduino reads three HC-SR04 ultrasonic sensors and transmits distance values over UART.
2. **Inference** — FPGA receives sensor data, runs it through the 3-8-3 network in a single clock-domain pipeline. Weights and biases are hardcoded as fixed-point constants.
3. **Actuation** — Output layer selects the motor command (forward / turn left / turn right) sent to the L298N driver.
4. **Training** — The network was trained offline in Python on collected driving data, then weights were quantized to Q6.10 and written into Verilog parameters.

## Tools

- Intel Quartus Prime (synthesis & programming)
- ModelSim (simulation)
- Arduino IDE
- Python / PyTorch (training)

## Board

Intel/Altera DE1-SoC (Cyclone V 5CSEMA5F31C6)

## Author

Mouhamad Alim Al-Amine  
[mouhamadalim.com](https://mouhamadalim.com)

## License

MIT License — see [LICENSE](LICENSE)
