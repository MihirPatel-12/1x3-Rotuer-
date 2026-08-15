//=============================================================================
// Layered SystemVerilog Testbench for ROUTER design
// (router_top / router_fifo / router_fsm / router_reg / router_sync)
//
// Put your 5 DUT files (router_top.v, router_fifo.V, router_fsm.v,
// router_reg.v, router_sync.v) in the "Design" panel on EDA Playground,
// and this file in the "Testbench" panel. Top module name: tb_top
//
// Packet format expected by the DUT:
//   Byte 0        : HEADER  -> bits[7:2] = payload length, bits[1:0] = address
//   Byte 1..N     : PAYLOAD data bytes            (packet_valid = 1)
//   Byte N+1      : PARITY  = header ^ payload[0] ^ ... ^ payload[N-1]
//                             driven with packet_valid = 0 (marks end of pkt)
//=============================================================================
`timescale 1ns/1ps

//=============================================================================
// INTERFACE
//=============================================================================
interface router_if(input bit clk);
  logic        resetn;
  logic        packet_valid;
  logic [7:0]  datain;
  logic        read_enb_0, read_enb_1, read_enb_2;
  logic        vldout_0, vldout_1, vldout_2;
  logic        err, busy;
  logic [7:0]  data_out_0, data_out_1, data_out_2;

  // Driver clocking block
  clocking drv_cb @(posedge clk);
    output packet_valid, datain, read_enb_0, read_enb_1, read_enb_2;
    input  vldout_0, vldout_1, vldout_2, err, busy;
    input  data_out_0, data_out_1, data_out_2;
  endclocking

  // Monitor clocking block
  clocking mon_cb @(posedge clk);
    input packet_valid, datain, read_enb_0, read_enb_1, read_enb_2;
    input vldout_0, vldout_1, vldout_2, err, busy;
    input data_out_0, data_out_1, data_out_2;
  endclocking
endinterface : router_if


//=============================================================================
// TRANSACTION
//=============================================================================
class transaction;
  rand bit [1:0]       addr;         // destination port: 0,1,2
  rand int unsigned    len;          // payload length
  rand bit             inject_err;   // force a parity error for negative testing
  rand bit [7:0]       payload[];

  bit [7:0] header;
  bit [7:0] true_parity;   // correct parity computed from header+payload
  bit [7:0] sent_parity;   // parity byte actually transmitted (may be corrupted)

  constraint c_addr  { addr inside {2'b00, 2'b01, 2'b10}; }
  constraint c_len   { len inside {[1:8]}; }
  constraint c_size  { payload.size() == len; }
  constraint c_err   { inject_err dist {0 :/ 85, 1 :/ 15}; }
  constraint c_order { solve len before payload; }

  function void post_randomize();
    header      = {len[5:0], addr};
    true_parity = header;
    foreach (payload[i]) true_parity = true_parity ^ payload[i];
    sent_parity = inject_err ? (true_parity ^ 8'hFF) : true_parity;
  endfunction

  function transaction copy();
    copy             = new();
    copy.addr        = addr;
    copy.len         = len;
    copy.inject_err  = inject_err;
    copy.payload     = payload;
    copy.header      = header;
    copy.true_parity = true_parity;
    copy.sent_parity = sent_parity;
  endfunction

  function void display(string tag);
    $display("[%0s] addr=%0d len=%0d header=%0h parity=%0h err_inj=%0b",
              tag, addr, len, header, sent_parity, inject_err);
  endfunction
endclass : transaction


//=============================================================================
// GENERATOR
//=============================================================================
class generator;
  mailbox #(transaction) gen2drv;
  event drv_done;
  int num_txn;

  function new(mailbox #(transaction) gen2drv, int num_txn);
    this.gen2drv = gen2drv;
    this.num_txn = num_txn;
  endfunction

  task run();
    transaction t;
    repeat (num_txn) begin
      t = new();
      if (!t.randomize()) $display("[GENERATOR] Randomization FAILED");
      gen2drv.put(t);
      @(drv_done);
    end
    $display("[GENERATOR] All %0d transactions generated", num_txn);
  endtask
endclass : generator


//=============================================================================
// COVERAGE
//=============================================================================
class coverage;
  virtual router_if vif;
  transaction t;

  covergroup txn_cg;
    option.per_instance = 1;
    addr_cp : coverpoint t.addr {
      bins port0 = {0};
      bins port1 = {1};
      bins port2 = {2};
    }
    len_cp : coverpoint t.len {
      bins len_small  = {[1:3]};
      bins len_medium = {[4:6]};
      bins len_large  = {[7:8]};
    }
    err_cp : coverpoint t.inject_err {
      bins no_err = {0};
      bins fault  = {1};
    }
    addr_x_err : cross addr_cp, err_cp;
    addr_x_len : cross addr_cp, len_cp;
  endgroup

  covergroup sig_cg @(posedge vif.clk);
    option.per_instance = 1;
    busy_cp  : coverpoint vif.busy;
    err_cp2  : coverpoint vif.err;
    vld0_cp  : coverpoint vif.vldout_0;
    vld1_cp  : coverpoint vif.vldout_1;
    vld2_cp  : coverpoint vif.vldout_2;
  endgroup

  function new(virtual router_if vif);
    this.vif = vif;
    txn_cg   = new();
    sig_cg   = new();
  endfunction

  function void sample_txn(transaction tr);
    t = tr;
    txn_cg.sample();
  endfunction

  function void report();
    $display("[COVERAGE] Transaction coverage : %0.2f %%", txn_cg.get_coverage());
    $display("[COVERAGE] Signal      coverage : %0.2f %%", sig_cg.get_coverage());
  endfunction
endclass : coverage


//=============================================================================
// DRIVER
//=============================================================================
class driver;
  virtual router_if vif;
  mailbox #(transaction) gen2drv;
  mailbox #(transaction) drv2sb;
  mailbox #(transaction) drv2errchk;
  coverage cov;
  event drv_done;

  function new(virtual router_if vif, mailbox #(transaction) gen2drv,
               mailbox #(transaction) drv2sb,
               mailbox #(transaction) drv2errchk);
    this.vif        = vif;
    this.gen2drv    = gen2drv;
    this.drv2sb     = drv2sb;
    this.drv2errchk = drv2errchk;
  endfunction

  task reset();
    vif.resetn            = 0;
    vif.drv_cb.packet_valid <= 0;
    vif.drv_cb.datain        <= 0;
    vif.drv_cb.read_enb_0    <= 0;
    vif.drv_cb.read_enb_1    <= 0;
    vif.drv_cb.read_enb_2    <= 0;
    repeat (5) @(posedge vif.clk);
    vif.resetn = 1;
    repeat (2) @(posedge vif.clk);
    $display("[DRIVER] Reset complete");
  endtask

  task drive_packet(transaction t);
    // The DUT only accepts a NEW header for a given destination port once
    // that port's FIFO has been fully drained (fifo_empty). If a new
    // packet is sent to a still-non-empty port, the FSM silently stalls
    // in its internal "wait_till_empty" state - and every byte presented
    // during that stall is simply lost (never captured). So we must wait
    // here until the destination is confirmed empty before presenting a
    // new header.
    case (t.addr)
      2'b00: while (vif.vldout_0) @(vif.drv_cb);
      2'b01: while (vif.vldout_1) @(vif.drv_cb);
      2'b10: while (vif.vldout_2) @(vif.drv_cb);
    endcase

    // Header
    @(vif.drv_cb);
    vif.drv_cb.packet_valid <= 1;
    vif.drv_cb.datain       <= t.header;

    // Bubble cycle: the DUT spends one cycle in its internal
    // "load_first_data" state after the header (loading the header into
    // its output register) before it is actually ready to consume the
    // first payload byte. packet_valid must stay high through this cycle;
    // the datain value here is a don't-care to the DUT.
    @(vif.drv_cb);
    vif.drv_cb.packet_valid <= 1;
    vif.drv_cb.datain       <= t.header;

    // Payload
    foreach (t.payload[i]) begin
      @(vif.drv_cb);
      vif.drv_cb.packet_valid <= 1;
      vif.drv_cb.datain       <= t.payload[i];
    end

    // Parity byte (packet_valid low marks last byte of packet)
    @(vif.drv_cb);
    vif.drv_cb.packet_valid <= 0;
    vif.drv_cb.datain       <= t.sent_parity;

    // Return to idle
    @(vif.drv_cb);
    vif.drv_cb.packet_valid <= 0;
    vif.drv_cb.datain       <= 0;

    // Inter-packet gap
    repeat ($urandom_range(2, 6)) @(vif.drv_cb);
  endtask

  task run();
    transaction t;
    forever begin
      gen2drv.get(t);
      t.display("DRIVER");

      // Push the expected bytes to the scoreboard BEFORE driving starts.
      // The DUT can start reading the header/payload back out of the FIFO
      // almost immediately (as soon as it's written), well before this
      // packet finishes driving - so the scoreboard must know the expected
      // data up front, not after the fact.
      drv2sb.put(t.copy());

      drive_packet(t);
      if (cov != null) cov.sample_txn(t);

      // Error flag only settles after the full packet + idle gap, so the
      // err check is reported on a separate mailbox once driving is done.
      drv2errchk.put(t.copy());
      ->drv_done;
    end
  endtask
endclass : driver


//=============================================================================
// READ AGENT  (independently pops data from the 3 output ports)
//=============================================================================
class read_agent;
  virtual router_if vif;

  function new(virtual router_if vif);
    this.vif = vif;
  endfunction

  task run();
    forever begin
      @(vif.drv_cb);
      vif.drv_cb.read_enb_0 <= ($urandom_range(0, 9) < 8);
      vif.drv_cb.read_enb_1 <= ($urandom_range(0, 9) < 8);
      vif.drv_cb.read_enb_2 <= ($urandom_range(0, 9) < 8);
    end
  endtask
endclass : read_agent


//=============================================================================
// MONITOR  (captures data read off each of the 3 output ports)
//=============================================================================
class monitor;
  virtual router_if vif;
  mailbox #(logic [7:0]) mon2sb_0, mon2sb_1, mon2sb_2;

  function new(virtual router_if vif,
               mailbox #(logic [7:0]) mon2sb_0,
               mailbox #(logic [7:0]) mon2sb_1,
               mailbox #(logic [7:0]) mon2sb_2);
    this.vif       = vif;
    this.mon2sb_0  = mon2sb_0;
    this.mon2sb_1  = mon2sb_1;
    this.mon2sb_2  = mon2sb_2;
  endfunction

  // router_fifo registers dataout one cycle after (read_enb & !empty),
  // so we pipeline the read request by one clock before sampling data_out_x.
  task run();
    bit pend0 = 0, pend1 = 0, pend2 = 0;
    forever begin
      @(vif.mon_cb);
      if (pend0) mon2sb_0.put(vif.mon_cb.data_out_0);
      if (pend1) mon2sb_1.put(vif.mon_cb.data_out_1);
      if (pend2) mon2sb_2.put(vif.mon_cb.data_out_2);

      pend0 = vif.mon_cb.read_enb_0 && vif.mon_cb.vldout_0;
      pend1 = vif.mon_cb.read_enb_1 && vif.mon_cb.vldout_1;
      pend2 = vif.mon_cb.read_enb_2 && vif.mon_cb.vldout_2;
    end
  endtask
endclass : monitor


//=============================================================================
// SCOREBOARD
//=============================================================================
class scoreboard;
  virtual router_if vif;
  mailbox #(transaction) drv2sb;       // fed immediately (before driving) -> expected data
  mailbox #(transaction) drv2errchk;   // fed after driving completes      -> err check
  mailbox #(logic [7:0]) mon2sb_0, mon2sb_1, mon2sb_2;

  bit [7:0] exp_q0[$], exp_q1[$], exp_q2[$];

  int data_match, data_mismatch;
  int err_match, err_mismatch;

  function new(virtual router_if vif, mailbox #(transaction) drv2sb,
               mailbox #(transaction) drv2errchk,
               mailbox #(logic [7:0]) mon2sb_0,
               mailbox #(logic [7:0]) mon2sb_1,
               mailbox #(logic [7:0]) mon2sb_2);
    this.vif        = vif;
    this.drv2sb     = drv2sb;
    this.drv2errchk = drv2errchk;
    this.mon2sb_0   = mon2sb_0;
    this.mon2sb_1   = mon2sb_1;
    this.mon2sb_2   = mon2sb_2;
  endfunction

  task run();
    fork
      recv_expected();
      recv_errchk();
      check_port(0);
      check_port(1);
      check_port(2);
    join_none
  endtask

  // Pushes expected bytes into the per-port queue the instant the driver
  // receives a transaction - i.e. before a single byte has been driven,
  // so it's always ahead of anything the monitor can observe.
  task recv_expected();
    transaction t;
    forever begin
      drv2sb.get(t);
      case (t.addr)
        2'b00: begin
          exp_q0.push_back(t.header);
          foreach (t.payload[i]) exp_q0.push_back(t.payload[i]);
          exp_q0.push_back(t.sent_parity);
        end
        2'b01: begin
          exp_q1.push_back(t.header);
          foreach (t.payload[i]) exp_q1.push_back(t.payload[i]);
          exp_q1.push_back(t.sent_parity);
        end
        2'b10: begin
          exp_q2.push_back(t.header);
          foreach (t.payload[i]) exp_q2.push_back(t.payload[i]);
          exp_q2.push_back(t.sent_parity);
        end
      endcase
    end
  endtask

  // Checks the err flag once the full packet (+ idle gap) has been driven,
  // by which time err has settled.
  task recv_errchk();
    transaction t;
    bit expected_err;
    forever begin
      drv2errchk.get(t);
      expected_err = t.inject_err;
      if (vif.err === expected_err) err_match++;
      else begin
        err_mismatch++;
        $display("[SCOREBOARD] ERR MISMATCH addr=%0d exp=%0b got=%0b",
                  t.addr, expected_err, vif.err);
      end
    end
  endtask

  task check_port(int port_num);
    logic [7:0] got, exp;
    forever begin
      case (port_num)
        0: mon2sb_0.get(got);
        1: mon2sb_1.get(got);
        2: mon2sb_2.get(got);
      endcase

      case (port_num)
        0: if (exp_q0.size() > 0) exp = exp_q0.pop_front(); else exp = 8'hxx;
        1: if (exp_q1.size() > 0) exp = exp_q1.pop_front(); else exp = 8'hxx;
        2: if (exp_q2.size() > 0) exp = exp_q2.pop_front(); else exp = 8'hxx;
      endcase

      if (got === exp) begin
        data_match++;
      end else begin
        data_mismatch++;
        $display("[SCOREBOARD] DATA MISMATCH port=%0d exp=%0h got=%0h",
                  port_num, exp, got);
      end
    end
  endtask

  function void report();
    $display("========================================================");
    $display("SCOREBOARD REPORT");
    $display("  Data  matches   : %0d", data_match);
    $display("  Data  mismatches: %0d", data_mismatch);
    $display("  Err   matches   : %0d", err_match);
    $display("  Err   mismatches: %0d", err_mismatch);
    if (data_mismatch == 0 && err_mismatch == 0)
      $display("  RESULT: PASS");
    else
      $display("  RESULT: FAIL");
    $display("========================================================");
  endfunction
endclass : scoreboard


//=============================================================================
// ENVIRONMENT
//=============================================================================
class environment;
  virtual router_if vif;

  generator   gen;
  driver      drv;
  monitor     mon;
  scoreboard  sb;
  coverage    cov;
  read_agent  rag;

  mailbox #(transaction) gen2drv;
  mailbox #(transaction) drv2sb;
  mailbox #(transaction) drv2errchk;
  mailbox #(logic [7:0])   mon2sb_0, mon2sb_1, mon2sb_2;

  event drv_done;
  int   num_txn = 30;

  function new(virtual router_if vif, int num_txn = 30);
    this.vif     = vif;
    this.num_txn = num_txn;

    gen2drv    = new();
    drv2sb     = new();
    drv2errchk = new();
    mon2sb_0   = new();
    mon2sb_1   = new();
    mon2sb_2   = new();

    gen = new(gen2drv, num_txn);
    gen.drv_done = drv_done;

    drv = new(vif, gen2drv, drv2sb, drv2errchk);
    drv.drv_done = drv_done;

    mon = new(vif, mon2sb_0, mon2sb_1, mon2sb_2);
    sb  = new(vif, drv2sb, drv2errchk, mon2sb_0, mon2sb_1, mon2sb_2);
    cov = new(vif);
    drv.cov = cov;
    rag = new(vif);
  endfunction

  task run();
    drv.reset();

    fork
      drv.run();
      mon.run();
      sb.run();
      rag.run();
    join_none

    gen.run();               // blocks until num_txn packets are sent

    repeat (60) @(posedge vif.clk);   // drain time

    sb.report();
    cov.report();
  endtask
endclass : environment


//=============================================================================
// TOP MODULE
//=============================================================================
module tb_top;
  bit clk;
  always #5 clk = ~clk;

  router_if vif(clk);

  // DUT instantiation
  router_top DUT (
    .clk          (clk),
    .resetn       (vif.resetn),
    .packet_valid (vif.packet_valid),
    .read_enb_0   (vif.read_enb_0),
    .read_enb_1   (vif.read_enb_1),
    .read_enb_2   (vif.read_enb_2),
    .datain       (vif.datain),
    .vldout_0     (vif.vldout_0),
    .vldout_1     (vif.vldout_1),
    .vldout_2     (vif.vldout_2),
    .err          (vif.err),
    .busy         (vif.busy),
    .data_out_0   (vif.data_out_0),
    .data_out_1   (vif.data_out_1),
    .data_out_2   (vif.data_out_2)
  );

  environment env;

  initial begin
    env = new(vif, 40);   // 40 packets
    env.run();
    $display("TESTBENCH COMPLETE");
    $finish;
  end

  // Watchdog
  initial begin
    #200000;
    $display("[WATCHDOG] TIMEOUT - forcing finish");
    $finish;
  end

  initial begin
    $dumpfile("router_tb.vcd");
    $dumpvars(0, tb_top);
  end
endmodule : tb_top