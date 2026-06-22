addpath('D:/work place/Matlab/ex18');
model = 'ex18_sfw_top';
load_system([model '.slx']);

vga_path = [model '/RF_VGA'];
pa_path = [model '/RF_PA'];

% --- Fix underlying block parameters ---
set_param(vga_path, 'DataSource', 'Gain and noise data');
set_param(vga_path, 'Gain', 'rf_vga_gain_db');
set_param(vga_path, 'RationalObject', '');
set_param(vga_path, 'Zin', 'rf_z0_ohm');
set_param(vga_path, 'Zout', 'rf_z0_ohm');

set_param(pa_path, 'DataSource', 'Gain and noise data');
set_param(pa_path, 'Gain', 'rf_pa_gain_db');
set_param(pa_path, 'RationalObject', '');
set_param(pa_path, 'Zin', 'rf_z0_ohm');
set_param(pa_path, 'Zout', 'rf_z0_ohm');

% --- Remove any self-mask (clean up from previous patch) ---
try Simulink.Mask.get(vga_path).delete(); catch; end
try Simulink.Mask.get(pa_path).delete(); catch; end

% --- Set OpenFcn for double-click editing ---
set_param(vga_path, 'OpenFcn', 'ex18_amp_dialog(gcb);');
set_param(pa_path, 'OpenFcn', 'ex18_amp_dialog(gcb);');

save_system([model '.slx']);
fprintf('Done. Double-click RF_VGA / RF_PA to edit gain.\n');
