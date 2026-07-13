// tb_croc_soc_fast.sv — Fast CROC SoC testbench (no JTAG loading)
//
// Loads hex directly into SRAM via hierarchy path, monitors core_status_q
// for EoC.  ~100x faster than JTAG-based tb_croc_soc.sv.

module tb_croc_soc_fast #(
  parameter int unsigned GpioCount = 32
);

  import croc_pkg::*;
  import tb_croc_pkg::*;

  // ───────────────────────────────────────────────
  // Clocks and reset
  // ───────────────────────────────────────────────
  logic rst_n, sys_clk, ref_clk;
  logic jtag_tck, jtag_trst_n, jtag_tms, jtag_tdi, jtag_tdo;
  logic uart_rx, uart_tx;
  logic [GpioCount-1:0] gpio_in, gpio_out, gpio_out_en;
  logic scan_out;
  logic fetch_en;

  // Clock and reset generation
  clk_rst_gen #(
    .ClkPeriod    ( ClkPeriodSys ),
    .RstClkCycles ( RstCycles    )
  ) i_clk_rst_sys (
    .clk_o  ( sys_clk ),
    .rst_no ( rst_n   )
  );

  clk_rst_gen #(
    .ClkPeriod    ( ClkPeriodRef ),
    .RstClkCycles ( RstCycles    )
  ) i_clk_rst_ref (
    .clk_o  ( ref_clk ),
    .rst_no ( )
  );

  // ───────────────────────────────────────────────
  // DUT
  // ───────────────────────────────────────────────
  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
    .clk_i          ( sys_clk     ),
    .rst_ni         ( rst_n       ),
    .ref_clk_i      ( ref_clk     ),
    .testmode_i     ( 1'b0        ),
    .fetch_en_i     ( fetch_en    ),
    .status_o       (             ),
    .jtag_tck_i     ( 1'b0        ),
    .jtag_tdi_i     ( 1'b0        ),
    .jtag_tdo_o     ( jtag_tdo    ),
    .jtag_tms_i     ( 1'b0        ),
    .jtag_trst_ni   ( rst_n       ),
    .uart_rx_i      ( 1'b1        ),  // idle high
    .uart_tx_o      ( uart_tx     ),
    .gpio_i         ( '0          ),
    .gpio_o         ( gpio_out    ),
    .gpio_out_en_o  ( gpio_out_en ),
    .scan_en_i      ( 1'b0        ),
    .scan_capture_i ( 1'b0        ),
    .scan_in_i      ( 1'b0        ),
    .scan_out_o     ( scan_out    )
  );

  // ───────────────────────────────────────────────
  // Command line args
  // ───────────────────────────────────────────────
  string binary_path;
  int max_cycles;

  initial begin
    if (!$value$plusargs("binary=%s", binary_path)) begin
      $display("[TB] ERROR: No +binary= provided");
      $finish;
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles))
      max_cycles = 200000;  // default
    $display("[TB] Program:    %s", binary_path);
    $display("[TB] Max cycles: %0d", max_cycles);
  end

  // ───────────────────────────────────────────────
  // Direct hex loading into SRAM (bypasses JTAG)
  // ───────────────────────────────────────────────
  task automatic load_hex_to_sram(input string filename);
    int fd, status;
    string line;
    bit [31:0] addr;
    bit [31:0] data;
    bit [7:0]  byte_data;
    int byte_count;
    int word_count;

    fd = $fopen(filename, "r");
    if (fd == 0) begin
      $fatal(1, "[TB] Cannot open hex file: %s", filename);
    end

    word_count = 0;

    while (!$feof(fd)) begin
      if ($fgets(line, fd) == 0) break;

      // '@' line = new address
      if (line[0] == "@") begin
        status = $sscanf(line, "@%h", addr);
        if (status != 1)
          $fatal(1, "[TB] Bad address line in hex: %s", line);
        $display("[TB] Loading @%08x", addr);
        continue;
      end

      // Data line: space-separated hex bytes
      byte_count = 0;
      data = 32'h0;

      while (line.len() > 0) begin
        status = $sscanf(line, "%h", byte_data);
        if (status != 1) break;

        // Place byte directly into correct lane (little-endian)
        case (byte_count)
          0: data[7:0]   = byte_data;
          1: data[15:8]  = byte_data;
          2: data[23:16] = byte_data;
          3: data[31:24] = byte_data;
        endcase
        byte_count++;

        // Skip past "XX " (2 hex + 1 space = 3 chars)
        if (line.len() > 3)
          line = line.substr(3, line.len()-1);
        else
          line = "";

        if (byte_count == 4) begin
          write_sram_word(addr, data);
          word_count++;
          addr += 4;
          data = 32'h0;
          byte_count = 0;
        end
      end

      // Handle trailing bytes (partial word) — already in correct lanes
      if (byte_count > 0) begin
        write_sram_word(addr, data);
        word_count++;
        addr += 4;
      end
    end

    $fclose(fd);
    $display("[TB] Loaded %0d words into SRAM", word_count);
  endtask

  task automatic write_sram_word(input bit [31:0] addr, input bit [31:0] data);
    int bank, word_idx;
    // Bank 0: 0x10000000 - 0x10000FFF  (1024 words)
    // Bank 1: 0x10001000 - 0x10001FFF  (1024 words)
    if (addr >= 32'h1000_1000) begin
      bank = 1;
      word_idx = (addr - 32'h1000_1000) >> 2;
    end else begin
      bank = 0;
      word_idx = (addr - 32'h1000_0000) >> 2;
    end

    if (word_idx < 0 || word_idx >= 1024) begin
      $display("[TB] WARN: addr 0x%08x out of SRAM range (word_idx=%0d)", addr, word_idx);
      return;
    end

    if (bank == 0)
      i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[word_idx] = data;
    else
      i_croc_soc.i_croc.gen_sram_bank[1].i_sram.i_tc_sram.sram[word_idx] = data;
  endtask

  // ───────────────────────────────────────────────
  // Core status register — direct hierarchy access
  // ───────────────────────────────────────────────
  wire [31:0] core_status = i_croc_soc.i_croc.i_soc_ctrl.core_status_q;

  // ───────────────────────────────────────────────
  // Main test sequence
  // ───────────────────────────────────────────────
  int cycle_count;

  initial begin
    $timeformat(-9, 0, "ns", 12);
    fetch_en = 1'b0;

    // Wait for EXTERNAL reset to deassert
    @(posedge rst_n);
    // Wait for INTERNAL reset (rstgen = 4 cycles) + margin
    repeat(10) @(posedge sys_clk);

    // Load hex directly into SRAM
    load_hex_to_sram(binary_path);

    // Verify SRAM content after loading
    $display("[TB] Verify: SRAM[0]=0x%08x (expect 0x00001197 for crt0)",
      i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[0]);
    $display("[TB] Verify: SRAM[815]=0x%08x (last partial word at 0x10000cbc)",
      i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[815]);
    $display("[TB] Verify: SRAM bank1[0]=0x%08x",
      i_croc_soc.i_croc.gen_sram_bank[1].i_sram.i_tc_sram.sram[0]);
    $display("[TB] Internal rst_n=%b, boot_addr=0x%08x, fetch_en_reg=%b",
      i_croc_soc.synced_rst_n,
      i_croc_soc.i_croc.i_soc_ctrl.boot_addr_q,
      i_croc_soc.i_croc.i_soc_ctrl.fetch_en_q);

    // Start the core
    $display("[TB] @%t | Starting core (fetch_en=1)", $time);
    fetch_en = 1'b1;

    // Wait for EoC: core_status[0] == 1
    cycle_count = 0;
    while (core_status[0] !== 1'b1) begin
      @(posedge sys_clk);
      cycle_count++;
      // Light debug: first 5 cycles for sanity, then every 50000
      if (cycle_count <= 5 || (cycle_count % 50000 == 0)) begin
        $display("[DBG] cyc=%0d | instr: req=%b gnt=%b rvalid=%b addr=0x%08x rdata=0x%08x",
          cycle_count,
          i_croc_soc.i_croc.i_core_wrap.instr_req_o,
          i_croc_soc.i_croc.i_core_wrap.instr_gnt_i,
          i_croc_soc.i_croc.i_core_wrap.instr_rvalid_i,
          i_croc_soc.i_croc.i_core_wrap.instr_addr_o,
          i_croc_soc.i_croc.i_core_wrap.instr_rdata_i);
      end
      if (cycle_count >= max_cycles) begin
        // Dump first 4 SRAM words for sanity check
        $display("[TB] SRAM[0]=0x%08x SRAM[1]=0x%08x SRAM[2]=0x%08x SRAM[3]=0x%08x",
          i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[0],
          i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[1],
          i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[2],
          i_croc_soc.i_croc.gen_sram_bank[0].i_sram.i_tc_sram.sram[3]);
        $display("[TB] boot_addr=0x%08x fetch_enable=%b debug_req=%b",
          i_croc_soc.i_croc.i_soc_ctrl.boot_addr_q,
          i_croc_soc.i_croc.fetch_enable,
          i_croc_soc.i_croc.debug_req);
        $display("[TB] TIMEOUT after %0d cycles", max_cycles);
        $display("[TB] core_status = 0x%08x", core_status);
        $finish;
      end
    end

    // Report result
    $display("[TB] @%t | EoC after %0d cycles", $time, cycle_count);
    $display("[TB] core_status = 0x%08x", core_status);
    if (core_status[31:1] == '0)
      $display("[TB] RESULT: PASS (return code 0)");
    else
      $display("[TB] RESULT: FAIL (return code 0x%0x)", core_status[31:1]);

    // Let UART flush
    repeat(200) @(posedge sys_clk);
    $finish;
  end

  // ───────────────────────────────────────────────
  // UART capture (same as croc_vip)
  // ───────────────────────────────────────────────
  localparam int unsigned ClkFrequency     = 1_000_000_000 / (ClkPeriodSys / 1ns);
  localparam int unsigned UartDivisor      = (ClkFrequency + UartBaudRate*8) / (UartBaudRate * 16);  // rounding, matches firmware uart.c
  localparam int unsigned UartRealBaudRate = ClkFrequency / (UartDivisor * 16);
  localparam realtime     UartBaudPeriod   = 1s / UartRealBaudRate;

  initial begin
    $display("[TB] ClkFrequency: %0d MHz", ClkFrequency / 1_000_000);
    $display("[TB] UartBaudRate: %0d", UartRealBaudRate);
  end

  task automatic uart_read_byte(output bit [7:0] bite);
    @(negedge uart_tx);
    #(UartBaudPeriod / 2);
    for (int i = 0; i < 8; i++) begin
      #UartBaudPeriod;
      bite[i] = uart_tx;
    end
    if (UartParityEna) begin
      bit parity;
      #UartBaudPeriod;
      parity = uart_tx;
      if (parity ^ (^bite))
        $error("[UART] Parity error!");
    end
    #UartBaudPeriod;  // stop bit
  endtask

  initial begin
    static bit [7:0] uart_buf[$];
    bit [7:0] bite;
    @(posedge fetch_en);
    uart_buf.delete();
    forever begin
      uart_read_byte(bite);
      if (bite == "\n" || uart_buf.size() > 80) begin
        if (uart_buf.size() > 0) begin
          automatic string s = "";
          foreach (uart_buf[i])
            s = {s, uart_buf[i]};
          $display("[UART] %s", s);
        end
        uart_buf.delete();
      end else begin
        uart_buf.push_back(bite);
      end
    end
  end

endmodule
