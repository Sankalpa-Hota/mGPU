// Kernels used by the SM and full-chip testbenches. Each kernel knows its code, its launch shape and how to
// fill its input data; a writer callback stores words so the same data goes to the DUT memory and the ISS.
// Memory map used by the kernels:  code 0x0000-0x3FFF, arguments 0x8000, A 0x10000, B 0x20000, OUT 0x40000
virtual class mgpu_data_writer;
  pure virtual function void write(bit [31:0] a, bit [31:0] d);
endclass

class mgpu_kernel;
  string name;
  mgpu_asm a;
  int num_wg = 4, nw = 2;
  bit [31:0] pc0 = 32'h0000, arg = 32'h8000;
  bit [31:0] A = 32'h10000, B = 32'h20000, OUT = 32'h40000;
  int seed;
  localparam int SHL = 6'h07, SHR = 6'h08, SLT = 6'h09, ANDOP = 6'h04, XOROP = 6'h06, OROP = 6'h05;

  function new(string name, int num_wg, int nw, int seed = 1);
    this.name = name; this.num_wg = num_wg; this.nw = nw; this.seed = seed;
    a = new(name);
    build();
    a.finish();
  endfunction
  function int threads(); return num_wg * nw * 8; endfunction

  // r1 = global thread id, r2 = 2 (shift by 4 bytes), r6 = argument base
  function void prologue();
    a.s2r(1, 3); a.addi(2, 0, 2); a.s2r(6, 4);
  endfunction
  // rd = base register + 4 * r1
  function void elem(int rd, int base_reg);
    a.r(SHL, rd, 1, 2); a.add(rd, rd, base_reg);
  endfunction

  virtual function void build();
    case (name)
      "vector_add": begin            // C[i] = A[i] + B[i]
        prologue();
        a.ld(3, 6, 0); a.ld(4, 6, 4); a.ld(5, 6, 8);
        elem(7, 3); elem(8, 4); elem(9, 5);
        a.ld(10, 7, 0); a.ld(11, 8, 0); a.add(12, 10, 11); a.st(12, 9, 0);
        a.exit_();
      end
      "saxpy": begin                 // OUT[i] = 3 * A[i] + B[i]
        prologue();
        a.ld(3, 6, 0); a.ld(4, 6, 4); a.ld(5, 6, 8);
        elem(7, 3); elem(8, 4); elem(9, 5);
        a.ld(10, 7, 0); a.ld(11, 8, 0); a.addi(12, 0, 3); a.mul(13, 10, 12); a.add(13, 13, 11); a.st(13, 9, 0);
        a.exit_();
      end
      "reduction": begin             // OUT[wg] = sum of the workgroup's elements of A, tree in shared memory
        a.s2r(1, 0); a.s2r(2, 1); a.addi(3, 0, 3); a.r(SHL, 4, 2, 3); a.add(4, 4, 1);   // r4 = local id
        a.s2r(5, 3); a.s2r(6, 4); a.ld(7, 6, 0); a.ld(8, 6, 4);
        a.addi(3, 0, 2); a.addi(15, 0, 1);
        a.r(SHL, 9, 5, 3); a.add(9, 9, 7); a.ld(10, 9, 0);            // x = A[gtid]
        a.r(SHL, 11, 4, 3); a.sts(10, 11, 0); a.bar();                // smem[lid] = x
        a.addi(12, 0, nw * 4);                                        // s = n / 2
        a.label("loop");
        a.r(SLT, 13, 4, 12); a.beq(13, 0, "skip", "skip");            // if (lid < s)
        a.r(SHL, 14, 12, 3); a.add(14, 14, 11);
        a.lds(10, 11, 0); a.lds(9, 14, 0); a.add(10, 10, 9); a.sts(10, 11, 0);
        a.label("skip");
        a.bar();
        a.r(SHR, 12, 12, 15); a.bne(12, 0, "loop", "after");
        a.label("after");
        a.bne(4, 0, "end", "end");                                    // thread 0 writes the sum
        a.s2r(5, 2); a.r(SHL, 5, 5, 3); a.add(5, 5, 8); a.lds(10, 0, 0); a.st(10, 5, 0);
        a.label("end");
        a.exit_();
      end
      "divergence": begin            // per-thread if / else, nested if and a loop with a per-thread trip count
        prologue();
        a.ld(3, 6, 0); a.ld(5, 6, 8); elem(7, 3); elem(9, 5); a.ld(10, 7, 0);
        a.addi(11, 0, 1); a.r(ANDOP, 12, 1, 11);
        a.beq(12, 0, "even", "j1");
        a.add(13, 10, 10); a.jmp("j1");                               // odd (runs second): y = 2x
        a.label("even"); a.addi(13, 10, 100);                         // even (taken, runs first): y = x + 100,
        a.addi(14, 0, 4); a.r(ANDOP, 14, 1, 14);                      // then a nested if / else while the odd
        a.beq(14, 0, "n_else", "n_join");                             // lanes still wait on the stack: depth 5
        a.addi(13, 13, 1000); a.jmp("n_join");
        a.label("n_else"); a.addi(13, 13, -7);
        a.label("n_join"); a.addi(13, 13, 1);                         // keeps the inner join apart from the outer one
        a.label("j1");
        a.addi(11, 0, 2); a.r(ANDOP, 12, 1, 11);
        a.beq(12, 0, "j2", "j2"); a.addi(14, 0, 'h55); a.r(XOROP, 13, 13, 14);
        a.label("j2");
        a.addi(11, 0, 5); a.r(6'h11, 12, 1, 11);                      // k = gtid % 5 (SFU)
        a.beq(12, 0, "done", "done");
        a.label("lp"); a.add(13, 13, 12); a.addi(12, 12, -1); a.bne(12, 0, "lp", "done");
        a.label("done");
        a.st(13, 9, 0); a.exit_();
      end
      "sfu": begin                   // OUT[i] = isqrt(x) + x / (i + 1) + x % 7
        prologue();
        a.ld(3, 6, 0); a.ld(5, 6, 8); elem(7, 3); elem(9, 5); a.ld(10, 7, 0);
        a.r(6'h12, 11, 10, 0); a.addi(12, 1, 1); a.r(6'h10, 13, 10, 12); a.addi(14, 0, 7); a.r(6'h11, 15, 10, 14);
        a.add(11, 11, 13); a.add(11, 11, 15); a.st(11, 9, 0); a.exit_();
      end
      "exit_barrier": begin          // odd warps and lanes 6-7 leave early; the others swap values through shared memory
        prologue();
        a.ld(3, 6, 0); a.ld(5, 6, 8); elem(7, 3); elem(9, 5); a.ld(10, 7, 0);
        a.s2r(11, 1); a.addi(12, 0, 1); a.r(ANDOP, 13, 11, 12);
        a.beq(13, 0, "stay", "stay"); a.st(10, 9, 0); a.exit_();      // odd warp: write x and leave
        a.label("stay");
        a.s2r(14, 0); a.addi(15, 0, 6); a.r(SLT, 12, 14, 15);         // lanes 6 and 7 (a neighbour pair) leave too
        a.bne(12, 0, "keep", "keep"); a.addi(13, 10, 7); a.st(13, 9, 0); a.exit_();
        a.label("keep");
        a.addi(12, 0, 3); a.r(SHL, 13, 11, 12); a.add(13, 13, 14);    // lid = warp * 8 + lane
        a.r(SHL, 15, 13, 2); a.sts(10, 15, 0); a.bar();
        a.addi(12, 0, 4); a.r(XOROP, 15, 15, 12); a.lds(8, 15, 0);    // neighbour (lid ^ 1)
        a.st(8, 9, 0); a.exit_();
      end
      "smem_conflict": begin         // all 8 lanes of a warp use one shared memory bank: 8 passes per access
        prologue();
        a.ld(3, 6, 0); a.ld(5, 6, 8); elem(7, 3); elem(9, 5); a.ld(10, 7, 0);
        a.s2r(11, 0); a.s2r(12, 1); a.addi(13, 0, 3);
        a.r(SHL, 14, 11, 13); a.add(14, 14, 12); a.r(SHL, 14, 14, 2);  // word = lane * 8 + warp
        a.sts(10, 14, 0); a.bar();
        a.addi(15, 11, 1); a.addi(13, 0, 7); a.r(ANDOP, 15, 15, 13);  // read the next lane's word (same bank)
        a.addi(13, 0, 3); a.r(SHL, 15, 15, 13); a.add(15, 15, 12); a.r(SHL, 15, 15, 2);
        a.lds(8, 15, 0); a.st(8, 9, 0); a.exit_();
      end
      default: random_kernel();
    endcase
  endfunction

  // working registers of the random kernel: never r1 (thread id), r2 (constant 2), r6 (argument base),
  // r13-r15 (addresses, loop counters), so the kernel can never store to a wild address
  int work[9] = '{3, 4, 5, 7, 8, 9, 10, 11, 12};

  // Random register-dump kernel: random ALU / SFU work on the working registers with divergent ifs and per-lane loops,
  // then every register is stored to OUT[(gtid * 16 + r) * 4] so any wrong value anywhere is visible.
  function void random_kernel();
    int lbl = 0;
    process p = process::self();
    p.srandom(seed);
    prologue();                                                   // r1 gtid, r2 = 2, r6 arg
    a.ld(13, 6, 0); elem(14, 13);                                 // r14 = &A[gtid]
    foreach (work[r]) a.ld(work[r], 14, 4 * r);                   // read 9 words around A[gtid]
    for (int k = 0; k < 18; k++) begin
      int c = $urandom_range(9);
      if (c <= 5) rand_op();
      else if (c <= 7) begin                                      // divergent if / else
        string e = $sformatf("e%0d", lbl), j = $sformatf("j%0d", lbl);
        lbl++;
        a.addi(15, 0, $urandom_range(7) + 1); a.r(ANDOP, 15, 1, 15);
        a.beq(15, 0, e, j);
        repeat ($urandom_range(3, 1)) rand_op();
        a.jmp(j);
        a.label(e);
        repeat ($urandom_range(3, 1)) rand_op();
        a.label(j);
      end else begin                                              // loop: 1..4 iterations depending on the lane
        string l = $sformatf("l%0d", lbl), d = $sformatf("d%0d", lbl);
        lbl++;
        a.addi(15, 0, 3); a.r(ANDOP, 15, 1, 15); a.addi(15, 15, 1);
        a.label(l);
        repeat ($urandom_range(2, 1)) rand_op();
        a.addi(15, 15, -1); a.bne(15, 0, l, d);
        a.label(d);
      end
    end
    a.ld(13, 6, 8); a.addi(15, 0, 6); a.r(SHL, 15, 1, 15); a.add(15, 15, 13);   // r15 = OUT + gtid * 64
    foreach (work[r]) a.st(work[r], 15, 4 * work[r]);
    a.exit_();
  endfunction

  function void rand_op();
    bit [5:0] ops[$] = '{6'h01, 6'h02, 6'h03, 6'h04, 6'h05, 6'h06, 6'h07, 6'h08, 6'h09, 6'h0A, 6'h10, 6'h11, 6'h12};
    bit [5:0] op = ops[$urandom_range(ops.size() - 1)];
    int rd = work[$urandom_range(8)], x = work[$urandom_range(8)], y = work[$urandom_range(8)];
    if (op == 6'h0A) a.addi(rd, x, $urandom_range(2000) - 1000);
    else a.r(op, rd, x, y);
  endfunction

  // the arguments and input data, written through the given writer (DUT memory and ISS both)
  function void setup(mgpu_data_writer w);
    // argument block: [0] = A, [4] = B (or OUT for the reduction), [8] = OUT
    w.write(arg, A);
    w.write(arg + 4, (name == "reduction") ? OUT : B);
    w.write(arg + 8, OUT);
    for (int i = 0; i < threads() + 16; i++) begin
      w.write(A + 4 * i, (name == "sfu") ? $urandom : $urandom_range(100000));
      w.write(B + 4 * i, $urandom_range(100000));
    end
    foreach (a.code[k]) w.write(pc0 + 4 * k, a.code[k]);
  endfunction
endclass
