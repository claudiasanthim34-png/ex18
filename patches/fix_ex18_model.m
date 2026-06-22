function fix_ex18_model()
%FIX_EX18_MODEL Fix ex18_sfw_top.slx for simulation and double-click editing.
%   - Switches RF_VGA/RF_PA from Rational model to Gain and noise data.
%   - Removes any stale self-masks.
%   - Sets OpenFcn for double-click gain/filter editing.
%   - Does NOT change block positions.

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);
model = 'ex18_sfw_top';

fprintf('=== Fixing %s ===\n', model);

if bdIsLoaded(model)
    close_system(model, 0);
end
load_system([model '.slx']);

vga = [model '/RF_VGA'];
pa  = [model '/RF_PA'];

% --- 1. Fix amplifier DataSource and clean masks ---
try Simulink.Mask.get(vga).delete(); catch; end
set_param(vga, 'DataSource', 'Gain and noise data');
set_param(vga, 'Gain', 'rf_vga_gain_db');
set_param(vga, 'RationalObject', '');
set_param(vga, 'Zin', 'rf_z0_ohm');
set_param(vga, 'Zout', 'rf_z0_ohm');
set_param(vga, 'OpenFcn', 'ex18_amp_dialog(gcb);');
fprintf('  RF_VGA: DataSource -> Gain and noise data, OpenFcn set.\n');

try Simulink.Mask.get(pa).delete(); catch; end
set_param(pa, 'DataSource', 'Gain and noise data');
set_param(pa, 'Gain', 'rf_pa_gain_db');
set_param(pa, 'RationalObject', '');
set_param(pa, 'Zin', 'rf_z0_ohm');
set_param(pa, 'Zout', 'rf_z0_ohm');
set_param(pa, 'OpenFcn', 'ex18_amp_dialog(gcb);');
fprintf('  RF_PA: DataSource -> Gain and noise data, OpenFcn set.\n');

% --- 2. Fix filter blocks: remove masks, set OpenFcn ---
filters = {'Tap_Up_BPF', 'RX_Down_IF_BPF', 'LPF_I', 'LPF_Q'};
for k = 1:numel(filters)
    blk = [model '/' filters{k}];
    try Simulink.Mask.get(blk).delete(); catch; end
    set_param(blk, 'OpenFcn', 'ex18_filter_dialog(gcb);');
    fprintf('  %s: OpenFcn set.\n', filters{k});
end

save_system([model '.slx']);
fprintf('=== Model saved. Ready for simulation. ===\n');
fprintf('Double-click amps to edit gain, filters to edit cutoff.\n');
end
