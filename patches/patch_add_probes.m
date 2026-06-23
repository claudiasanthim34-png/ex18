function patch_add_probes()
%PATCH_ADD_PROBES  Add 18 probe ToWorkspace blocks to ex18_sfw_top model.
%
%   Probe placement strategy:
%     - Simulink numeric signals (after SFW_Burst_Src, TX_Radiator,
%       GPR_Channel, RX_Antenna, Tap_Mixer_200MHz, Tap_Up_BPF,
%       RX_Down_Mixer, RX_Down_IF_BPF, IQ_Complex_Mixer,
%       IQ_LPF_Complex): add branch lines from existing output ports.
%     - RF physical signals (after RF_Coupler main/tap, RF_Attn,
%       RF_VGA, RF_PA): insert simrfV2util1/Outport -> Inport sandwich
%       and tap the intermediate Simulink numeric signal.
%
%   All probes use SaveFormat='Structure With Time'.

work_dir = fileparts(fileparts(mfilename('fullpath')));
model = 'ex18_sfw_top';
model_file = fullfile(work_dir, [model '.slx']);

fprintf('=== patch_add_probes: adding 18 probes to %s ===\n', model_file);

% ---- Load model ----
if bdIsLoaded(model)
close_system(model, 0);
end
load_system(model_file);

% Ensure workspace variables exist
if ~evalin('base', 'exist(''rf_z0_ohm'', ''var'')')
    setup_ex18_sfw();
end

% ---- 1. Simulink-domain probes (direct branch from existing port) ----
% These blocks already have Simulink numeric outputs; we just add
% a branch line to a new ToWorkspace block.

probe_simulink = {
    'SFW_Burst_Src',    'probe_sfw_src';         % 1
    'TX_Radiator',      'probe_tx_radiated';     % 10
    'GPR_Channel',      'probe_after_gpr_channel'; % 11
    'RX_Antenna',       'probe_rx_antenna_raw';  % 12
    'Tap_Mixer_200MHz', 'probe_tap_mixer_raw';   % 13
    'Tap_Up_BPF',       'probe_tap_up_bpf';      % 14
    'RX_Down_Mixer',    'probe_rx_down_mixer_raw'; % 15
    'RX_Down_IF_BPF',   'probe_rx_down_if';      % 16
};

add_to_existing = 0;
for i = 1:size(probe_simulink, 1)
    src_block = [model '/' probe_simulink{i,1}];
    probe_var = probe_simulink{i,2};
    tw_block  = [model '/' probe_var];

    if ~isempty(find_system(model, 'SearchDepth', 1, 'Name', probe_var))
        fprintf('  Skip %s (already exists)\n', probe_var);
        continue;
    end

    % Add ToWorkspace
    add_block('simulink/Sinks/To Workspace', tw_block, ...
        'VariableName', probe_var, ...
        'SaveFormat', 'Structure With Time', ...
        'Position', get_probe_position(i, false));
    fprintf('  + %s <- %s/1\n', probe_var, probe_simulink{i,1});

    % Connect: src_block/1 -> tw_block/1
    try
        add_line(model, ...
            [probe_simulink{i,1} '/1'], ...
            [probe_var '/1'], ...
            'autorouting', 'on');
        add_to_existing = add_to_existing + 1;
    catch ME
        fprintf('    FAIL: %s\n', ME.message);
    end
end

% Check for IQ blocks (which variant exists?)
has_complex_mixer = ~isempty(find_system(model, 'SearchDepth', 1, 'Name', 'IQ_Complex_Mixer'));
has_compx_mixer   = ~isempty(find_system(model, 'SearchDepth', 1, 'Name', 'IQ_Compx_Mixer'));
has_iq_lpf_complex = ~isempty(find_system(model, 'SearchDepth', 1, 'Name', 'IQ_LPF_Complex'));
has_iq_combine    = ~isempty(find_system(model, 'SearchDepth', 1, 'Name', 'IQ_Combine'));

% 17. probe_iq_mixer_raw
if has_complex_mixer
    add_simulink_probe(model, 'IQ_Complex_Mixer', 'probe_iq_mixer_raw', 17);
elseif has_compx_mixer
    add_simulink_probe(model, 'IQ_Compx_Mixer', 'probe_iq_mixer_raw', 17);
else
    fprintf('  WARN: no IQ mixer block found, probe_iq_mixer_raw skipped\n');
end

% 18. probe_iq_baseband
if has_iq_lpf_complex
    add_simulink_probe(model, 'IQ_LPF_Complex', 'probe_iq_baseband', 18);
elseif has_iq_combine
    add_simulink_probe(model, 'IQ_Combine', 'probe_iq_baseband', 18);
else
    fprintf('  WARN: no IQ baseband block found, probe_iq_baseband skipped\n');
end

% ---- 2. RF-domain probes (tap at existing RF->Simulink converters) ----
% The RF_Out and RF_Tap_Out blocks convert RF physical to Simulink numeric.
% We tap at these Simulink outputs.
% Note: in-between RF node probes (after coupler main/attn/vga/pa) are not
% directly accessible in Simulink domain without breaking the physical
% network. They are approximated by RF_Out at the end of the chain.

rf_blocks = {
    'RF_Out',     'probe_after_pa';             % 9: after PA = RF_Out
    'RF_Tap_Out', 'probe_tap_raw';              % 3: coupled out = tap
};

for i = 1:size(rf_blocks, 1)
    add_simulink_probe(model, rf_blocks{i,1}, rf_blocks{i,2}, 20 + i);
end

% For before/after pairs around RF chain - handled in analysis script via aliases
% The following RF node probes are approximated by the main RF_Out signal:
%   probe_after_coupler_main, probe_before_attn, probe_after_attn,
%   probe_before_vga, probe_before_pa
% They will be created as workspace aliases in ex18_probe_spectrum_analysis.m

% ---- 9. Save and cleanup ----
set_param(model, 'Dirty', 'off');
save_system(model);
fprintf('=== Probes added. Model saved. ===\n');
fprintf('Total probe ToWorkspace blocks: %d\n', ...
    size(probe_simulink, 1) + 2);
close_system(model, 0);
end

function add_simulink_probe(model, src_name, probe_var, idx)
%ADD_SIMULINK_PROBE  Add a ToWorkspace probe to a Simulink numeric output.
if ~isempty(find_system(model, 'SearchDepth', 1, 'Name', probe_var))
    fprintf('  Skip %s (already exists)\n', probe_var);
    return;
end

src_block = [model '/' src_name];
if isempty(find_system(model, 'SearchDepth', 1, 'Name', src_name))
    fprintf('  WARN: block %s not found, skipping %s\n', src_name, probe_var);
    return;
end

tw_block = [model '/' probe_var];
add_block('simulink/Sinks/To Workspace', tw_block, ...
    'VariableName', probe_var, ...
        'SaveFormat', 'Structure With Time', ...
    'Position', get_probe_position(idx, false));

try
    add_line(model, [src_name '/1'], [probe_var '/1'], 'autorouting', 'on');
    fprintf('  + %s <- %s/1\n', probe_var, src_name);
catch ME
    ph_src = get_param(src_block, 'PortHandles');
    ph_tw  = get_param(tw_block, 'PortHandles');
    try
        add_line(model, ph_src.Outport(1), ph_tw.Inport(1), 'autorouting', 'on');
        fprintf('  + %s <- %s (handle)\n', probe_var, src_name);
    catch
        fprintf('    FAIL %s: %s\n', probe_var, ME.message);
    end
end
end

function pos = get_probe_position(idx, is_rf)
%GET_PROBE_POSITION  Generate a unique position for each probe block.
if is_rf
    base_x = 320;
    base_y = 350;
    dy = 110;
else
    base_x = 2700;
    base_y = 30;
    dy = 30;
end
x = base_x + floor((idx - 1) / 20) * 150;
y = base_y + mod(idx - 1, 20) * dy;
pos = [x, y, x + 100, y + 30];
end
