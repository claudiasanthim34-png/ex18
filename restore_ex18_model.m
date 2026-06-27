function restore_ex18_model()
%RESTORE_EX18_MODEL  将 ex18_sfw_top.slx 恢复至运行 ex18_observe_requested_spectra 之前的状态。
%
%   恢复优先级：
%     1. 如果存在 _temp_bak.slx（ex18_observe_requested_spectra 的备份），从备份恢复
%     2. 否则通过 git checkout HEAD 恢复至当前已提交的版本
%
%   用法：
%     restore_ex18_model

model = 'ex18_sfw_top';
work_dir = fileparts(mfilename('fullpath'));
model_file = fullfile(work_dir, [model '.slx']);
bak_file = fullfile(work_dir, [model '_temp_bak.slx']);
slxc_file = fullfile(work_dir, [model '.slxc']);

fprintf('=== Restoring ex18 circuit ===\n');

if bdIsLoaded(model)
    fprintf('  Closing model without saving...\n');
    close_system(model, 0);
end

if exist(bak_file, 'file') == 2
    fprintf('  Found temp backup, restoring from %s\n', bak_file);
    copyfile(bak_file, model_file);
    delete(bak_file);
else
    fprintf('  No temp backup found, restoring from git HEAD\n');
    cmd = sprintf('git -C "%s" checkout HEAD -- ex18_sfw_top.slx', work_dir);
    [status, result] = system(cmd);
    if status ~= 0
        error('git checkout HEAD 失败：%s', result);
    end
end
fprintf('  OK\n');

if exist(slxc_file, 'file') == 2
    delete(slxc_file);
    fprintf('  Deleted .slxc cache\n');
end

fprintf('=== Done: circuit restored ===\n');
end
