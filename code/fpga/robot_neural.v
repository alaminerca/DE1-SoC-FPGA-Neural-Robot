// robot_neural.v — Top-level module (v2: 3-distance servo scan)
// Receives 3 distance bytes via UART, runs neural network, sends class back
// Protocol: Arduino sends [dist_left, dist_center, dist_right], FPGA replies [class]
// Classes: 0=FORWARD, 1=STOP, 2=TURN

module robot_neural (
    input  wire        CLOCK_50,
    input  wire [1:0]  KEY,        // KEY[0]=reset, KEY[1]=kill switch
    input  wire [9:0]  SW,         // SW[0]=enable inference
    output wire [9:0]  LEDR,       // status LEDs
    output wire [6:0]  HEX0,       // show class on 7-seg
    inout  wire [35:0] GPIO_0
);

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       tx_busy;

    // ==================== ACTIVE / KILL SWITCH ====================
    // SW[0] = master enable. When OFF, FPGA does not respond.
    // KEY[1] = emergency stop (active-low). Press to force class=STOP.
    wire active = SW[0];
    wire kill   = ~KEY[1];  // pressed = kill = force STOP

    // ==================== UART RX ====================
    uart_rx u_rx (
        .clk       (CLOCK_50),
        .rst_n     (KEY[0]),
        .rx        (GPIO_0[0]),
        .data_out  (rx_data),
        .data_valid(rx_valid)
    );

    // ==================== UART TX ====================
    reg [7:0] tx_data;
    reg       tx_send;

    uart_tx u_tx (
        .clk       (CLOCK_50),
        .rst_n     (KEY[0]),
        .data_in   (tx_data),
        .data_send (tx_send),
        .tx        (GPIO_0[1]),
        .busy      (tx_busy)
    );

    // ==================== BYTE COLLECTOR ====================
    reg [7:0] sensor_left;       // byte 0: dist_left  (0-255)
    reg [7:0] sensor_center;     // byte 1: dist_center (0-255)
    reg [7:0] sensor_right;      // byte 2: dist_right (0-255)
    reg [1:0] byte_count;
    reg       nn_trigger;

    always @(posedge CLOCK_50 or negedge KEY[0]) begin
        if (!KEY[0]) begin
            byte_count    <= 2'd0;
            sensor_left   <= 8'd0;
            sensor_center <= 8'd0;
            sensor_right  <= 8'd0;
            nn_trigger    <= 1'b0;
        end else begin
            nn_trigger <= 1'b0;
            if (rx_valid && active) begin
                case (byte_count)
                    2'd0: begin sensor_left   <= rx_data; byte_count <= 2'd1; end
                    2'd1: begin sensor_center <= rx_data; byte_count <= 2'd2; end
                    2'd2: begin sensor_right  <= rx_data; byte_count <= 2'd0;
                                nn_trigger    <= 1'b1; end
                    default: byte_count <= 2'd0;
                endcase
            end
        end
    end

    // ==================== INPUT SCALING ====================
    // Convert 8-bit bytes to Q6.10 fixed-point via multiply-by-4 (<<2).
    // Maps: 0→0.000, 128→0.500, 255→0.996 in Q6.10.
    // The NN was trained with [0,1] normalized inputs, so this matches.
    wire signed [15:0] nn_in0 = {6'd0, sensor_left,   2'd0};  // byte * 4
    wire signed [15:0] nn_in1 = {6'd0, sensor_center,  2'd0};  // byte * 4
    wire signed [15:0] nn_in2 = {6'd0, sensor_right,  2'd0};  // byte * 4

    // ==================== NEURAL NETWORK ====================
    wire [1:0] nn_class;
    wire       nn_done;

    neural_net u_nn (
        .clk         (CLOCK_50),
        .rst_n       (KEY[0]),
        .in0         (nn_in0),
        .in1         (nn_in1),
        .in2         (nn_in2),
        .input_valid (nn_trigger),
        .class_out   (nn_class),
        .output_valid(nn_done)
    );

    // ==================== OUTPUT WITH KILL SWITCH ====================
    wire [1:0] final_class = kill ? 2'd1 : nn_class;  // kill → force STOP

    always @(posedge CLOCK_50 or negedge KEY[0]) begin
        if (!KEY[0]) begin
            tx_data <= 8'd0;
            tx_send <= 1'b0;
        end else begin
            tx_send <= 1'b0;
            if (nn_done && !tx_busy && active) begin
                tx_data <= {6'd0, final_class};
                tx_send <= 1'b1;
            end
        end
    end

    // ==================== STATUS DISPLAY ====================
    // LEDs: show last class + activity
    assign LEDR[1:0] = final_class;
    assign LEDR[2]   = active;
    assign LEDR[3]   = kill;
    assign LEDR[9:4] = 6'd0;

    // 7-segment: show class number on HEX0
    reg [6:0] hex_val;
    always @(*) begin
        case (final_class)
            2'd0: hex_val = 7'b0001110;  // F (Forward)
            2'd1: hex_val = 7'b0010010;  // S (Stop)
            2'd2: hex_val = 7'b0000111;  // t (Turn)
            default: hex_val = 7'b1111111; // blank
        endcase
    end
    assign HEX0 = ~hex_val;  // DE1-SoC 7-seg is active-low

endmodule
