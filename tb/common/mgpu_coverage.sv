// Bin counter used instead of covergroups: Verilator parses covergroups but does not count their bins.
// Each bin is a name; sample(name) increments it. The report lists the percentage and every bin never hit.
class mgpu_coverage;
  string name;
  int    hits[string];
  string order[$];

  function new(string name);
    this.name = name;
  endfunction

  function void add_bin(string b);
    if (!hits.exists(b)) begin
      hits[b] = 0;
      order.push_back(b);
    end
  endfunction

  function void sample(string b);
    if (hits.exists(b)) hits[b]++;
  endfunction

  function real percent();
    int n = 0;
    foreach (order[i]) if (hits[order[i]] > 0) n++;
    return order.size() == 0 ? 0.0 : 100.0 * n / order.size();
  endfunction

  function string report();
    string s = "";
    foreach (order[i]) s = {s, $sformatf("\n    %-28s %0d", order[i], hits[order[i]])};
    return s;
  endfunction
endclass
