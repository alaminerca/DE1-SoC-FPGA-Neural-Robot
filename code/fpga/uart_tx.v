// uart_tx.v — UART Transmitter
// 9600 baud, 50 MHz clock, 8N1
// VERIFIED WORKING — do not modify

module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data_in,
    input  wire       data_send,
    output reg        tx,
    output reg        busy
);

    localparam CLKS_PER_BIT = 5208;

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [12:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  tx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            clk_count <= 13'd0;
            bit_index <= 3'd0;
            tx        <= 1'b1;  // idle high
            busy      <= 1'b0;
            tx_shift  <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    if (data_send) begin
                        tx_shift  <= data_in;
                        clk_count <= 13'd0;
                        busy      <= 1'b1;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;  // start bit
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 13'd0;
                        bit_index <= 3'd0;
                        state     <= S_DATA;
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                S_DATA: begin
                    tx <= tx_shift[bit_index];
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 13'd0;
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
                    tx <= 1'b1;  // stop bit
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        state <= S_IDLE;
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
