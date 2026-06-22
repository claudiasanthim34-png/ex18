addpath('D:/work place/Matlab/ex18');
model = 'ex18_sfw_top';
load_system([model '.slx']);

tap_bpf = [model '/Tap_Up_BPF'];
rx_if_bpf = [model '/RX_Down_IF_BPF'];
lpf_i = [model '/LPF_I'];
lpf_q = [model '/LPF_Q'];

% --- Remove any self-masks (clean up from previous patch) ---
for blk = {tap_bpf, rx_if_bpf, lpf_i, lpf_q}
    try Simulink.Mask.get(blk{1}).delete(); catch; end
end

% --- Set OpenFcn for double-click editing ---
set_param(tap_bpf, 'OpenFcn', 'ex18_filter_dialog(gcb);');
set_param(rx_if_bpf, 'OpenFcn', 'ex18_filter_dialog(gcb);');
set_param(lpf_i, 'OpenFcn', 'ex18_filter_dialog(gcb);');
set_param(lpf_q, 'OpenFcn', 'ex18_filter_dialog(gcb);');

save_system([model '.slx']);
fprintf('Done. Double-click filters to edit cutoff.\n');
