// uart_rx.v — UART Receiver
// 9600 baud, 50 MHz clock, 8N1
// 2-stage synchronizer for metastability protection
// VERIFIED WORKING — do not modify

module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg [7:0]  data_out,
    output reg        data_valid
);

    localparam CLKS_PER_BIT = 5208;  // 50_000_000 / 9600
    localparam HALF_BIT     = 2604;  // sample at midpoint

    // Metastability synchronizer
    reg rx_sync1, rx_sync2;
    always @(posedge clk) begin
        rx_sync1 <= rx;
        rx_sync2 <= rx_sync1;
    end

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [12:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  rx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_count  <= 13'd0;
            bit_index  <= 3'd0;
            data_out   <= 8'd0;
            data_valid <= 1'b0;
            rx_shift   <= 8'd0;
        end else begin
            data_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (rx_sync2 == 1'b0) begin  // falling edge = start bit
                        clk_count <= 13'd0;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    if (clk_count == HALF_BIT) begin
                        if (rx_sync2 == 1'b0) begin  // still low at midpoint
                            clk_count <= 13'd0;
                            bit_index <= 3'd0;
                            state     <= S_DATA;
                        end else begin
                            state <= S_IDLE;  // false start
                        end
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                S_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 13'd0;
                        rx_shift[bit_index] <= rx_sync2;
                        if (bit_index == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                S_STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        data_out   <= rx_shift;
                        data_valid <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
