class disp_rand_seq extends uvm_sequence #(disp_kernel);
  `uvm_object_utils(disp_rand_seq)
  int n = 30, max_wg = 12;
  function new(string name = "disp_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      disp_kernel k = disp_kernel::type_id::create("k");
      k.max_wg = max_wg;
      start_item(k);
      if (!k.randomize()) `uvm_fatal("RAND", "kernel")
      finish_item(k);
    end
  endtask
endclass
