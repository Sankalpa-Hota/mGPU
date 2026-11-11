class icache_rand_seq extends uvm_sequence #(icache_fetch);
  `uvm_object_utils(icache_rand_seq)
  int n = 50, max_len = 12, max_gap = 2, hi_pct = 0;
  bit [31:0] region = 32'h1000;
  function new(string name = "icache_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      icache_fetch f = icache_fetch::type_id::create("f");
      f.max_len = max_len; f.max_gap = max_gap; f.region = region; f.hi_pct = hi_pct;
      start_item(f);
      if (!f.randomize()) `uvm_fatal("RAND", "fetch")
      finish_item(f);
    end
  endtask
endclass
