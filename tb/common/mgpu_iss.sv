// Instruction set simulator: runs every thread of a kernel on its own (no warps, no SIMT stack), which is the
// true meaning of the program. Barriers are resolved per workgroup: each thread runs until it reaches BAR or
// EXIT; when every thread that has not exited is at the barrier, all of them continue.
// Its global memory after the kernel is the golden result for the hardware.
class mgpu_iss;
  bit [31:0] mem[bit [31:0]];     // word-addressed by byte address (bits [1:0] = 0)
  int        steps;
  string     error;

  function bit [31:0] rd(bit [31:0] a); a[1:0] = 0; return mem.exists(a) ? mem[a] : 32'h0; endfunction
  function void wr(bit [31:0] a, bit [31:0] d); a[1:0] = 0; mem[a] = d; endfunction

  function bit [31:0] isqrt(bit [31:0] a);
    longint unsigned r = 0;
    for (int b = 15; b >= 0; b--) begin longint unsigned t = r | (64'd1 << b); if (t * t <= a) r = t; end
    return r;
  endfunction

  // returns 0 when finished, 1 at a barrier, 2 when the step budget ran out
  function int run_thread(ref bit [31:0] R[16], ref bit [31:0] pc, ref bit [31:0] smem[128],
                          input int lane, int warp, int wg, int nw, bit [31:0] arg);
    forever begin
      bit [31:0] ins = rd(pc);
      bit [5:0] op = ins[31:26];
      int d = ins[25:22], s1 = ins[21:18], s2 = ins[17:14];
      bit [31:0] a = R[s1], b = R[s2], imm = {{14{ins[17]}}, ins[17:0]}, res;
      bit [31:0] tgt = pc + ({{23{ins[17]}}, ins[17:9]} << 2);
      int sa = a, sb = b;
      bit wb = 1;
      steps++;
      if (steps > 2000000) begin error = "step budget exceeded (infinite loop?)"; return 2; end
      case (op)
        6'h00: wb = 0;
        6'h01: res = a + b;
        6'h02: res = a - b;
        6'h03: res = a * b;
        6'h04: res = a & b;
        6'h05: res = a | b;
        6'h06: res = a ^ b;
        6'h07: res = a << b[4:0];
        6'h08: res = a >> b[4:0];
        6'h09: res = (sa < sb) ? 1 : 0;
        6'h0A: res = a + imm;
        6'h0B: res = imm << 14;
        6'h0C: case (ins[17:0])
                 0: res = lane; 1: res = warp; 2: res = wg; 3: res = (wg * nw + warp) * 8 + lane; 4: res = arg;
                 default: res = 0;
               endcase
        6'h10: res = (b == 0) ? 32'hFFFF_FFFF : a / b;
        6'h11: res = (b == 0) ? a : a % b;
        6'h12: res = isqrt(a);
        6'h18: res = rd(a + imm);
        6'h19: begin wr(a + imm, R[d]); wb = 0; end
        6'h1A: res = smem[((a + imm) >> 2) % 128];
        6'h1B: begin smem[((a + imm) >> 2) % 128] = R[d]; wb = 0; end
        6'h20: begin pc = (R[d] == a) ? tgt : pc + 4; continue; end
        6'h21: begin pc = (R[d] != a) ? tgt : pc + 4; continue; end
        6'h22: begin pc = tgt; continue; end
        6'h23: begin pc = pc + 4; return 1; end
        6'h3F: return 0;
        default: wb = 0;
      endcase
      if (wb && d != 0) R[d] = res;
      pc = pc + 4;
    end
  endfunction

  // run a whole kernel; returns 1 on success
  function bit run_kernel(bit [31:0] pc0, int num_wg, int nw, bit [31:0] arg);
    steps = 0; error = "";
    for (int wg = 0; wg < num_wg; wg++) begin
      int n = nw * 8;
      bit [31:0] R[32][16];
      bit [31:0] pc[32];
      int        st[32];      // 0 running, 1 at barrier, 2 exited
      bit [31:0] smem[128];
      for (int t = 0; t < n; t++) begin pc[t] = pc0; st[t] = 0; for (int k = 0; k < 16; k++) R[t][k] = 0; end
      forever begin
        bit any_bar = 0, all_exit = 1;
        for (int t = 0; t < n; t++)
          if (st[t] == 0) begin
            int r = run_thread(R[t], pc[t], smem, t % 8, t / 8, wg, nw, arg);
            if (r == 2) return 0;
            st[t] = (r == 1) ? 1 : 2;
          end
        for (int t = 0; t < n; t++) begin if (st[t] == 1) any_bar = 1; if (st[t] != 2) all_exit = 0; end
        if (all_exit) break;
        for (int t = 0; t < n; t++) if (st[t] == 1) st[t] = 0;    // every live thread is at the barrier: release
      end
    end
    return 1;
  endfunction
endclass
