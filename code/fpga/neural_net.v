// neural_net.v — v5 (3 fixed sensors, aggressive turn, no servo)
// Sequential neural network — reuses one multiplier to save DSP blocks
// Architecture: 3 → 8 (ReLU) → 3 → argmax
// Fixed-point: signed 16-bit Q6.10
// Classes: 0=FORWARD, 1=STOP, 2=TURN
// Latency: ~50 clock cycles (~1us at 50MHz)
// Total parameters: 59 (24 + 8 + 24 + 3 weights/biases)
//
// INPUT CONVENTION: Inputs arrive as Q6.10 values.
//   The top-level module converts raw 0-255 bytes via: byte * 4
//   This maps 0→0.000, 255→0.996 in Q6.10 (≈ [0,1] range).
//   Weights were trained with [0,1] normalized inputs.

module neural_net (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [15:0] in0,   // dist_left  (Q6.10)
    input  wire signed [15:0] in1,   // dist_center (Q6.10)
    input  wire signed [15:0] in2,   // dist_right (Q6.10)
    input  wire        input_valid,
    output reg  [1:0]  class_out,    // 0=FWD, 1=STOP, 2=TURN
    output reg         output_valid
);

    // ===================== STATE MACHINE =====================
    localparam S_IDLE   = 3'd0;
    localparam S_LAYER1 = 3'd1;  // 8 neurons, 3 weights each
    localparam S_LAYER2 = 3'd2;  // 3 neurons, 8 weights each
    localparam S_ARGMAX = 3'd3;

    reg [2:0] state;
    reg [3:0] neuron;    // which neuron (0-7 for L1, 0-2 for L2)
    reg [3:0] input_idx; // which input weight
    reg signed [31:0] acc;

    // ===================== LAYER STORAGE =====================
    reg signed [15:0] inputs [0:2];
    reg signed [15:0] l1 [0:7];   // layer 1 outputs (8 neurons)
    reg signed [15:0] l2 [0:2];   // layer 2 outputs (3 neurons)

    // ===================== WEIGHT LOOKUP =====================
    // Layer 1: W1[input][neuron], 3x8 = 24 weights
    function signed [15:0] get_w1;
        input [1:0] inp;
        input [2:0] neu;
        reg [4:0] idx;
        begin
            idx = inp * 8 + neu;
            case (idx)
                 0: get_w1=16'sh0019;
                 1: get_w1=16'sh14F4;
                 2: get_w1=16'sh0021;
                 3: get_w1=16'sh06E1;
                 4: get_w1=16'sh100B;
                 5: get_w1=16'shFFED;
                 6: get_w1=16'sh0E02;
                 7: get_w1=16'sh14BC;
                 8: get_w1=16'shFFD7;
                 9: get_w1=16'sh013F;
                10: get_w1=16'shFFD6;
                11: get_w1=16'shFD4A;
                12: get_w1=16'sh13E7;
                13: get_w1=16'shFF66;
                14: get_w1=16'shFA90;
                15: get_w1=16'shFB65;
                16: get_w1=16'shFFAE;
                17: get_w1=16'sh011D;
                18: get_w1=16'shFFB5;
                19: get_w1=16'shFD5F;
                20: get_w1=16'sh1126;
                21: get_w1=16'shFFEE;
                22: get_w1=16'shFC7F;
                23: get_w1=16'shFCB2;
                default: get_w1=16'sh0000;
            endcase
        end
    endfunction

    function signed [15:0] get_b1;
        input [2:0] neu;
        begin
            case (neu)
                 0: get_b1=16'shFFBE;
                 1: get_b1=16'shFFBA;
                 2: get_b1=16'shFFB0;
                 3: get_b1=16'shFBE4;
                 4: get_b1=16'shFF78;
                 5: get_b1=16'sh0000;
                 6: get_b1=16'shF78B;
                 7: get_b1=16'shFE77;
                default: get_b1=16'sh0000;
            endcase
        end
    endfunction

    // Layer 2: W2[input][neuron], 8x3 = 24 weights
    function signed [15:0] get_w2;
        input [2:0] inp;
        input [1:0] neu;
        reg [4:0] idx;
        begin
            idx = inp * 3 + neu;
            case (idx)
                 0: get_w2=16'shFFD4;
                 1: get_w2=16'sh0008;
                 2: get_w2=16'shFFA5;
                 3: get_w2=16'sh10E2;
                 4: get_w2=16'shF5CF;
                 5: get_w2=16'shF926;
                 6: get_w2=16'shFFD0;
                 7: get_w2=16'sh0093;
                 8: get_w2=16'sh0001;
                 9: get_w2=16'sh056D;
                10: get_w2=16'sh0036;
                11: get_w2=16'shF9E8;
                12: get_w2=16'sh0BDA;
                13: get_w2=16'shE676;
                14: get_w2=16'sh0CB9;
                15: get_w2=16'sh0010;
                16: get_w2=16'sh003B;
                17: get_w2=16'sh000E;
                18: get_w2=16'sh0B33;
                19: get_w2=16'shFFD7;
                20: get_w2=16'shF45D;
                21: get_w2=16'shF119;
                22: get_w2=16'shFFA0;
                23: get_w2=16'sh0F3D;
                default: get_w2=16'sh0000;
            endcase
        end
    endfunction

    function signed [15:0] get_b2;
        input [1:0] neu;
        begin
            case (neu)
                0: get_b2=16'shF07A;
                1: get_b2=16'sh11E7;
                2: get_b2=16'shFD9E;
                default: get_b2=16'sh0000;
            endcase
        end
    endfunction

    // ===================== MAIN STATE MACHINE =====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            neuron       <= 4'd0;
            input_idx    <= 4'd0;
            acc          <= 32'sd0;
            class_out    <= 2'd0;
            output_valid <= 1'b0;
        end else begin
            output_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (input_valid) begin
                        inputs[0] <= in0;
                        inputs[1] <= in1;
                        inputs[2] <= in2;
                        neuron    <= 4'd0;
                        input_idx <= 4'd0;
                        acc       <= get_b1(3'd0) * 1024;
                        state     <= S_LAYER1;
                    end
                end

                // ---- Layer 1: 3 inputs x 8 neurons (ReLU) ----
                S_LAYER1: begin
                    acc <= acc + inputs[input_idx[1:0]] * get_w1(input_idx[1:0], neuron[2:0]);

                    if (input_idx == 4'd2) begin
                        input_idx <= 4'd3;  // one extra cycle to capture final add
                    end else if (input_idx == 4'd3) begin
                        // Store with ReLU
                        l1[neuron[2:0]] <= (acc < 0) ? 16'sd0 : acc[25:10];

                        if (neuron == 4'd7) begin
                            neuron    <= 4'd0;
                            input_idx <= 4'd0;
                            acc       <= get_b2(2'd0) * 1024;
                            state     <= S_LAYER2;
                        end else begin
                            neuron    <= neuron + 4'd1;
                            input_idx <= 4'd0;
                            acc       <= get_b1(neuron[2:0] + 3'd1) * 1024;
                        end
                    end else begin
                        input_idx <= input_idx + 4'd1;
                    end
                end

                // ---- Layer 2: 8 inputs x 3 neurons (no ReLU) ----
                S_LAYER2: begin
                    acc <= acc + l1[input_idx[2:0]] * get_w2(input_idx[2:0], neuron[1:0]);

                    if (input_idx == 4'd7) begin
                        input_idx <= 4'd8;
                    end else if (input_idx == 4'd8) begin
                        l2[neuron[1:0]] <= acc[25:10];  // signed, no ReLU

                        if (neuron == 4'd2) begin
                            state <= S_ARGMAX;
                        end else begin
                            neuron    <= neuron + 4'd1;
                            input_idx <= 4'd0;
                            acc       <= get_b2(neuron[1:0] + 2'd1) * 1024;
                        end
                    end else begin
                        input_idx <= input_idx + 4'd1;
                    end
                end

                // ---- Argmax: find winning class ----
                S_ARGMAX: begin
                    if (l2[0] >= l2[1] && l2[0] >= l2[2])
                        class_out <= 2'd0;  // FORWARD
                    else if (l2[1] >= l2[2])
                        class_out <= 2'd1;  // STOP
                    else
                        class_out <= 2'd2;  // TURN

                    output_valid <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
