// tb_croc_soc.sv — CROC SoC + MX Unified Coprocessor Testbench
//
// Adapted from reference tb_croc_soc.sv to add scan chain port connections.
// Scan chain is tied off (scan_en=0, scan_capture=0, scan_in=0) for
// functional simulation.  For fault injection, use tb_chip.sv instead.

`define TRACE_WAVE

module tb_croc_soc #(
  parameter int unsigned GpioCount = 32
);

  import tb_croc_pkg::*;

  // Signals fully controlled by the VIP
  logic rst_n;
  logic sys_clk;
  logic ref_clk;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_rx;
  logic uart_tx;

  // GPIO
  logic [GpioCount-1:0] gpio_in;
  logic [GpioCount-1:0] gpio_out;
  logic [GpioCount-1:0] gpio_out_en;

  // Scan chain (tied off for functional sim)
  logic scan_out;

  // Testbench control
  logic fetch_en;

  /////////////////////////////
  //  Command Line Arguments //
  /////////////////////////////

  string binary_path;

  initial begin
    if ($value$plusargs("binary=%s", binary_path)) begin
      $display("Running program: %s", binary_path);
    end else begin
      $display("No binary path provided. Running helloworld.");
      binary_path = "../sw/bin/helloworld.hex";
    end
  end

  ////////////
  //  VIP   //
  ////////////

  croc_vip #(
    .GpioCount ( GpioCount )
  ) i_vip (
    .rst_no        ( rst_n       ),
    .sys_clk_o     ( sys_clk     ),
    .ref_clk_o     ( ref_clk     ),
    .fetch_en_i    ( fetch_en    ),
    .jtag_tck_o    ( jtag_tck    ),
    .jtag_trst_no  ( jtag_trst_n ),
    .jtag_tms_o    ( jtag_tms    ),
    .jtag_tdi_o    ( jtag_tdi    ),
    .jtag_tdo_i    ( jtag_tdo    ),
    .uart_rx_o     ( uart_rx     ),
    .uart_tx_i     ( uart_tx     ),
    .gpio_out_en_i ( gpio_out_en ),
    .gpio_out_i    ( gpio_out    ),
    .gpio_in_o     ( gpio_in     )
  );

  ////////////
  //  DUT   //
  ////////////

  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
    .clk_i          ( sys_clk     ),
    .rst_ni         ( rst_n       ),
    .ref_clk_i      ( ref_clk     ),
    .testmode_i     ( 1'b0        ),
    .fetch_en_i     ( fetch_en    ),
    .status_o       (             ),
    .jtag_tck_i     ( jtag_tck    ),
    .jtag_tdi_i     ( jtag_tdi    ),
    .jtag_tdo_o     ( jtag_tdo    ),
    .jtag_tms_i     ( jtag_tms    ),
    .jtag_trst_ni   ( jtag_trst_n ),
    .uart_rx_i      ( uart_rx     ),
    .uart_tx_o      ( uart_tx     ),
    .gpio_i         ( gpio_in     ),
    .gpio_o         ( gpio_out    ),
    .gpio_out_en_o  ( gpio_out_en ),
    // Scan chain tied off for functional sim
    .scan_en_i      ( 1'b0        ),
    .scan_capture_i ( 1'b0        ),
    .scan_in_i      ( 1'b0        ),
    .scan_out_o     ( scan_out    )
  );

  /////////////////
  //  Testbench  //
  /////////////////

  logic [31:0] tb_data;

  initial begin
    $timeformat(-9, 0, "ns", 12);

    fetch_en = 1'b0;

    // wait for reset
    #ClkPeriodSys;

    // init jtag
    i_vip.jtag_init();

    // write test value to sram
    i_vip.jtag_write_reg32(SramBaseAddr, 32'h1234_5678, 1'b1);
    // load binary to sram
    i_vip.jtag_load_hex(binary_path);

    $display("@%t | [CORE] Start fetching instructions", $time);
    fetch_en = 1'b1;

    // halt core
    i_vip.jtag_halt();

    // resume core
    i_vip.jtag_resume();

    // wait for non-zero return value (written into core status register)
    $display("@%t | [CORE] Wait for end of code...", $time);
    i_vip.jtag_wait_for_eoc(tb_data);

    // finish simulation
    repeat(50) @(posedge sys_clk);
    $finish();
  end

  ////////////////
  //  Waveform  //
  ////////////////
  initial begin
    `ifdef TRACE_WAVE
      `ifdef VERILATOR
        $dumpfile("croc.fst");
        $dumpvars(0, i_croc_soc);
      `else
        $dumpfile("croc.vcd");
        $dumpvars(1, i_croc_soc);
      `endif
    `endif
  end

  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule
