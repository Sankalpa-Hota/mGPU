// CP ring fetch: reads command dwords from the ring buffer in memory and streams them to the packet decoder.
// Memory port: one request = one 32-byte line (8 dwords), one 256-bit response beat.
// One request outstanding at a time. A request is issued only if the FIFO has room for every dword it will keep.
module cp_ring_fetch #(
  parameter int RING_LOG2  = 10,   // ring size in dwords = 2^RING_LOG2 (at least 8)
  parameter int FIFO_DEPTH = 16
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [31:0]          ring_base,   // byte address, 32-byte aligned
  input  logic [RING_LOG2-1:0] wptr,        // dword index written by the CPU
  output logic [RING_LOG2-1:0] rptr,        // dword index delivered to the decoder
  output logic                 mreq_valid,
  input  logic                 mreq_ready,
  output logic [31:0]          mreq_addr,
  input  logic                 mrsp_valid,
  input  logic [255:0]         mrsp_data,
  output logic                 dw_valid,
  input  logic                 dw_ready,
  output logic [31:0]          dw_data,
  output logic                 busy
);
  localparam int CW = $clog2(FIFO_DEPTH + 1);

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT} state_t;
  state_t state;

  logic [RING_LOG2-1:0] fptr;            // next dword to fetch
  logic [RING_LOG2-1:0] avail;
  logic [3:0]           to_line_end;
  logic [3:0]           n_take, n_q;
  logic [2:0]           off_q;

  logic [31:0]          fifo_mem [FIFO_DEPTH];
  logic [$clog2(FIFO_DEPTH)-1:0] wr_idx, rd_idx;
  logic [CW-1:0]        count;
  logic                 pop;

  assign avail       = wptr - fptr;
  assign to_line_end = 4'd8 - {1'b0, fptr[2:0]};
`ifdef BUG_LINE_CROSS
  assign n_take      = (avail >= 8) ? 4'd8 : avail[3:0];
`else
  assign n_take      = (avail >= RING_LOG2'(to_line_end)) ? to_line_end : avail[3:0];
`endif

  assign mreq_valid = (state == S_REQ);
  assign mreq_addr  = ring_base + {{(32-RING_LOG2-2){1'b0}}, fptr[RING_LOG2-1:3], 5'b00000};

  assign dw_valid = (count != 0);
  assign dw_data  = fifo_mem[rd_idx];
  assign pop      = dw_valid && dw_ready;
  assign busy     = (state != S_IDLE) || (count != 0) || (wptr != fptr);

  logic room;
`ifdef BUG_FIFO_ROOM
  assign room = (FIFO_DEPTH - count) >= (n_take - 1);
`else
  assign room = (FIFO_DEPTH - count) >= n_take;
`endif

  logic           push;
  assign push = (state == S_WAIT) && mrsp_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      fptr   <= '0;
      rptr   <= '0;
      n_q    <= '0;
      off_q  <= '0;
      wr_idx <= '0;
      rd_idx <= '0;
      count  <= '0;
    end else begin
      case (state)
        S_IDLE: if (avail != 0 && room) begin
          n_q   <= n_take;
          off_q <= fptr[2:0];
          state <= S_REQ;
        end
        S_REQ:  if (mreq_ready) state <= S_WAIT;
        S_WAIT: if (mrsp_valid) begin
          fptr  <= fptr + RING_LOG2'(n_q);
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase

      if (push) begin
        for (int i = 0; i < 8; i++)
          if (i < n_q) fifo_mem[wr_idx + i[$clog2(FIFO_DEPTH)-1:0]] <= mrsp_data[32*(off_q + i) +: 32];
        wr_idx <= wr_idx + n_q[$clog2(FIFO_DEPTH)-1:0];
      end
      if (pop) begin
        rd_idx <= rd_idx + 1'b1;
        rptr   <= rptr + 1'b1;
      end
      count <= count + (push ? CW'(n_q) : '0) - (pop ? CW'(1) : '0);
    end
  end
endmodule
