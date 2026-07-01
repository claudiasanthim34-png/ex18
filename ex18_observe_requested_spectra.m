%% ex18_observe_requested_spectra.m
% 频谱观测脚本（非侵入式版本）
%
% 功能：运行后固定输出以下 14 张观测图：
%   01_SFW_Burst_Src输出_时域波形与时频图.png
%   02_SFW_Burst_Src输出_步进频率信号源频谱.png
%   03_RF_Out输出_发射天线前频谱.png
%   04_TX_Radiator输出_发射天线后频谱.png
%   05_RF_Out与TX_Radiator_发射天线前后频谱对比.png
%   06_RX_Antenna输出_接收回波原始频谱.png
%   07_Tap_Mixer_200MHz输出_上变频混频后宽频频谱.png
%   08_Tap_Up_BPF输出_上变频滤波后上边带频谱.png
%   09_RX_Down_Mixer输出_下变频混频后宽频频谱.png
%   10_RX_Down_IF_BPF输出_rx_down_if_log1中频频谱.png
%   11_IQ混频输出_LPF前双边复频谱.png
%   12_IQ混频LPF后复基带_rx_iq_baseband_log1频谱.png
%   13_IQ基带输出_双边复频谱.png
%   14_IFFT前后_复频响幅频相频曲线.png
%
% 重要原则：
%   本脚本不会在原始 Simulink 电路上添加、删除或保存任何模块。
%   脚本会先把模型文件复制到临时目录，随后只在临时模型中添加 To Workspace
%   探针并运行仿真。仿真结束后关闭临时模型，不保存临时模型。
%
% 使用方法：
%   1. 将本脚本放在 ex18 仓库根目录，或放在模型 .slx/.mdl 所在目录；
%   2. 在 MATLAB 当前目录切换到脚本所在目录；
%   3. 运行本脚本；
%   4. 结果图片保存在 ./spectrum_observation_results_nonintrusive/。
%
% 如果某个节点没有自动找到：
%   先运行脚本，查看命令行中输出的候选块名称；
%   然后在下面"用户可调参数"中的 probeList 里补充该节点的真实块名。

clear; clc; close all;

%% ========================= 用户可调参数 =========================

% 是否在运行结束后把生成的 14 张图窗弹出来。
% true  ：保存 PNG 后保留并弹出 MATLAB 图窗；
% false ：只保存 PNG，不主动弹出图窗。
showFiguresAfterSave = true;

% 原始模型名称。留空时，脚本会在当前目录自动寻找 .slx/.mdl。
% 如果目录里有多个模型，请手动写成如 'ex18.slx' 或 'ex18.mdl'。
modelFile = '';

% 仿真停止时间。留空时使用模型自身 StopTime。
% 如果只想快速看频谱，可以写成 '1e-6'、'2e-6' 等。
overrideStopTime = '';

% 输出图片目录。
resultDirName = 'spectrum_observation_results_nonintrusive';

% 需要观测的节点配置。
% name      ：脚本内部使用的节点名；
% title     ：节点中文说明；
% match     ：按块名匹配的候选关键词/正则表达式，脚本会从前到后查找；
% portType  ：'out' 表示取该块输出；'in' 表示取该块输入；
% portIndex ：端口序号，一般为 1。
%
% 下面这些节点对应最终要输出的 14 张图。IFFT 前后共用同一个 IFFT 块：
%   - ifft_input 取 IFFT 输入端；
%   - ifft_output 取 IFFT 输出端。

%  定义需要观测的13个节点
probeList = [
    struct( ...
        'name', 'sfw_src', ...
        'title', 'SFW_Burst_Src 输出', ...
        'match', {{'^SFW_Burst_Src$', 'SFW[_ ]?Burst[_ ]?Src', 'Burst.*Src', 'SFW'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'rf_out', ...
        'title', 'RF_Out 输出', ...
        'match', {{'^RF_Out$', '^RF Out$', 'RF[_ ]?Out', 'RF.*Output'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'tx_radiator', ...
        'title', 'TX_Radiator 输出', ...
        'match', {{'^TX_Radiator$', '^TX Radiator$', 'TX[_ ]?Radiator', 'Transmit.*Radiator', 'Radiator'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'rx_antenna', ...
        'title', 'RX_Antenna 输出', ...
        'match', {{'^RX_Antenna$', '^RX Antenna$', 'RX[_ ]?Antenna', 'Receive.*Antenna', 'Antenna'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'tap_mixer_200mhz', ...
        'title', 'Tap_Mixer_200MHz 输出', ...
        'match', {{'^Tap_Mixer_200MHz$', 'Tap[_ ]?Mixer[_ ]?200MHz', 'Tap.*Mixer.*200', 'Mixer.*200'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'tap_up_bpf', ...
        'title', 'Tap_Up_BPF 输出', ...
        'match', {{'^Tap_Up_BPF$', 'Tap[_ ]?Up[_ ]?BPF', 'Up.*BPF', 'BPF'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'rx_down_mixer', ...
        'title', 'RX_Down_Mixer 输出', ...
        'match', {{'^RX_Down_Mixer$', 'RX[_ ]?Down[_ ]?Mixer', 'Down.*Mixer', 'RX.*Mixer'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'rx_down_if', ...
        'title', 'RX_Down_IF_BPF 输出（rx_down_if_log1）', ...
        'match', {{'^RX_Down_IF_BPF$', '^RX_Down_IF_BPF1$', 'RX[_ ]?Down[_ ]?IF[_ ]?BPF', 'Down.*IF.*BPF', 'IF.*BPF'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'iq_mixer', ...
        'title', 'IQ 混频输出（LPF 前）', ...
        'match', {{'^IQ_Complex_Mixer1$', '^IQ_Complex_Mixer$', 'IQ.*Complex.*Mixer', 'IQ.*Mixer', 'IQ.*Mix'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'iq_filtered', ...
        'title', 'IQ 混频 LPF 后复基带（IQ_Combine1/rx_iq_baseband_log1）', ...
        'match', {{'^IQ_Combine1$', '^IQ_Combine$', 'IQ[_ ]?Combine', 'Real.*Imag.*Complex', 'RealImagToComplex'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'iq_baseband', ...
        'title', 'IQ 基带输出', ...
        'match', {{'^IQ_Combine1$', '^IQ_Combine$', 'IQ[_ ]?Combine', 'Real.*Imag.*Complex', ...
            '^IQ_Baseband$', '^IQ Baseband$', 'IQ.*Baseband', ...
            'Complex.*Baseband', 'Baseband'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'ifft_input', ...
        'title', 'IFFT 前复频响', ...
        'match', {{'^IFFT$', 'IFFT', 'Inverse.*FFT'}}, ...
        'portType', 'in', ...
        'portIndex', 1) ...
    struct( ...
        'name', 'ifft_output', ...
        'title', 'IFFT 后复频响/距离像', ...
        'match', {{'^IFFT$', 'IFFT', 'Inverse.*FFT'}}, ...
        'portType', 'out', ...
        'portIndex', 1) ...
];

% 频谱图纵轴是否归一化到最大值 0 dB。
normalizeSpectrumToPeak = true;

% 是否使用窗函数。脉冲/突发信号本身会带来谱展宽，使用 Hann 窗可降低旁瓣。
useHannWindow = true;

%% ========================= 脚本主体 =========================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

if isempty(modelFile)
    modelFile = autoFindModelFile(scriptDir);
else
    modelFile = fullfile(scriptDir, modelFile);
end

if ~isfile(modelFile)
    error('没有找到模型文件：%s', modelFile);
end

[modelDir, modelBase, modelExt] = fileparts(modelFile);
resultDir = fullfile(modelDir, resultDirName);
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

fprintf('\n=== ex18 频谱观测（非侵入式版本）===\n');
fprintf('原始模型：%s\n', modelFile);
fprintf('结果目录：%s\n', resultDir);

% 把原模型复制到临时目录。后续所有探针都加在临时模型里。
% 如果原模型已经在 MATLAB 中打开，为了避免同名模型冲突，临时模型会换一个名称。
tempRoot = tempname;
mkdir(tempRoot);
cleanupObj = onCleanup(@()cleanupTempModel(tempRoot));

originalLoaded = bdIsLoaded(modelBase);
if originalLoaded
    tempModelBase = [modelBase '_spectrum_tmp_' datestr(now, 'yyyymmdd_HHMMSS')];
    fprintf('检测到原模型已打开：临时模型将使用新名称 %s。\n', tempModelBase);
else
    tempModelBase = modelBase;
end

tempModelFile = fullfile(tempRoot, [tempModelBase modelExt]);
copyfile(modelFile, tempModelFile);

% 保留原仓库目录在路径中，避免模型初始化脚本、MAT 文件或自定义函数找不到。
oldPath = path;
pathCleanupObj = onCleanup(@()path(oldPath));
addpath(modelDir);
addpath(tempRoot);

tmpModel = tempModelBase;
load_system(tempModelFile);
modelCleanupObj = onCleanup(@()closeTempModel(tmpModel));

% 让 To Workspace 的数据返回到 simOut 中，避免污染 base workspace。
trySetModelParam(tmpModel, 'ReturnWorkspaceOutputs', 'on');
trySetModelParam(tmpModel, 'SignalLogging', 'on');

if ~isempty(overrideStopTime)
    trySetModelParam(tmpModel, 'StopTime', overrideStopTime);
end

% 在临时模型中挂接探针。
attached = struct('name', {}, 'title', {}, 'varName', {}, ...
    'portType', {}, 'blockPath', {});

fprintf('\n--- 正在寻找并挂接观测节点 ---\n');
for k = 1:numel(probeList)
    probe = probeList(k);
    blockPath = findBlockByName(tmpModel, probe.match);

    if isempty(blockPath)
        fprintf('[跳过] %s：没有找到匹配块。\n', probe.title);
        printUsefulCandidates(tmpModel, probe.name);
        continue;
    end

    % To Workspace 探针变量名使用 obs_ 前缀，避免和模型中已有的
    % probe_iq_baseband 等观测节点重名。
    varName = ['obs_' probe.name];
    try
        attachToWorkspaceProbe(tmpModel, blockPath, probe.portType, ...
            probe.portIndex, varName);
        attached(end + 1) = struct( ...
            'name', probe.name, ...
            'title', probe.title, ...
            'varName', varName, ...
            'portType', probe.portType, ...
            'blockPath', blockPath); %#ok<SAGROW>
        fprintf('[完成] %-12s -> %s (%s%d)\n', ...
            probe.name, blockPath, probe.portType, probe.portIndex);
    catch ME
        fprintf('[跳过] %s：探针挂接失败：%s\n', probe.title, ME.message);
    end
end

missingProbeNames = setdiff({probeList.name}, {attached.name}, 'stable');
optionalFallbackProbeNames = {'iq_baseband'};
missingCriticalProbeNames = setdiff(missingProbeNames, optionalFallbackProbeNames, 'stable');
if ~isempty(missingCriticalProbeNames)
    fprintf('\n以下必需观测节点没有成功挂接：\n');
    for i = 1:numel(missingCriticalProbeNames)
        fprintf('  %s\n', missingCriticalProbeNames{i});
    end
    error(['没有成功挂接全部必需节点。请根据上方候选块名称，' ...
        '修改脚本开头 probeList 中对应节点的 match 字段。']);
end
if ismember('iq_baseband', missingProbeNames)
    fprintf(['\n[提示] 没有找到独立的 IQ 基带输出节点，' ...
        '后续将使用 IFFT 输入端信号生成第 13 张 IQ 基带频谱图。\n']);
end

% 运行临时模型仿真。注意：运行的是临时模型，不是原模型。
fprintf('\n--- 正在运行临时模型仿真 ---\n');
try
    simIn = Simulink.SimulationInput(tmpModel);
    if ~isempty(overrideStopTime)
        simIn = simIn.setModelParameter('StopTime', overrideStopTime);
    end
    simOut = sim(simIn);
catch
    % 旧版 MATLAB 若不支持 SimulationInput，则退回普通 sim 调用。
    if ~isempty(overrideStopTime)
        simOut = sim(tmpModel, 'StopTime', overrideStopTime);
    else
        simOut = sim(tmpModel);
    end
end
fprintf('仿真完成。\n');

% 读取探针数据并按固定清单出图。
fprintf('\n--- 正在生成指定的 12 张频谱观测图片 ---\n');
oldDefaultFigureVisible = get(0, 'DefaultFigureVisible');
if showFiguresAfterSave
    set(0, 'DefaultFigureVisible', 'on');
else
    set(0, 'DefaultFigureVisible', 'off');
end
figureVisibleCleanup = onCleanup(@()set(0, 'DefaultFigureVisible', oldDefaultFigureVisible));

signals = collectProbeSignals(simOut, attached);
if ~isfield(signals, 'iq_baseband')
    signals.iq_baseband = signals.ifft_input;
end
savedFiles = {};

fig = figure('Color', 'w', 'Name', 'SFW_Burst_Src输出_时域波形与时频图');
plotTimeAndSpectrogram(signals.sfw_src.x, signals.sfw_src.t, ...
    'SFW_Burst_Src 输出：时域波形与时频图');
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '01_SFW_Burst_Src输出_时域波形与时频图.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'SFW_Burst_Src输出_步进频率信号源频谱');
plotDoubleSidedSpectrum(signals.sfw_src.x, signals.sfw_src.t, ...
    'SFW_Burst_Src 输出：步进频率信号源频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '02_SFW_Burst_Src输出_步进频率信号源频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'RF_Out输出_发射天线前频谱');
% %plotDoubleSidedSpectrum(signals.rf_out.x, signals.rf_out.t, ...
%     'RF_Out 输出：发射天线前频谱', ...
%     normalizeSpectrumToPeak, useHannWindow);
% plotLinearSpectrum(signals.rf_out.x, signals.rf_out.t, ...
%     'RF_Out 输出：发射天线前频谱', ...
%      useHannWindow);
plotAbsoluteDbSpectrum(signals.rf_out.x, signals.rf_out.t, ...
    'RF_Out 输出：发射天线前频谱', ...
    useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '03_RF_Out输出_发射天线前频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'TX_Radiator输出_发射天线后频谱');
% plotDoubleSidedSpectrum(signals.tx_radiator.x, signals.tx_radiator.t, ...
%     'TX_Radiator 输出：发射天线后频谱', ...
%     normalizeSpectrumToPeak, useHannWindow);
% plotLinearSpectrum(signals.rf_out.x, signals.rf_out.t, ...
%     'TX_Radiator 输出：发射天线后频谱', ...
%      useHannWindow);
plotAbsoluteDbSpectrum(signals.rf_out.x, signals.rf_out.t, ...
    'TX_Radiator 输出：发射天线后频谱', ...
    useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '04_TX_Radiator输出_发射天线后频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'RF_Out与TX_Radiator_发射天线前后频谱对比');
% plotSpectrumCompare(signals.rf_out.x, signals.rf_out.t, 'RF_Out 天线前', ...
%     signals.tx_radiator.x, signals.tx_radiator.t, 'TX_Radiator 天线后', ...
%     'RF_Out 与 TX_Radiator：发射天线前后频谱对比', ...
%     normalizeSpectrumToPeak, useHannWindow);
plotAbsoluteDbSpectrumCompare(signals.rf_out.x, signals.rf_out.t, 'RF_Out 天线前', ...
    signals.tx_radiator.x, signals.tx_radiator.t, 'TX_Radiator 天线后', ...
    'RF_Out 与 TX_Radiator：发射天线前后频谱对比', ...
     useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '05_RF_Out与TX_Radiator_发射天线前后频谱对比.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'RX_Antenna输出_接收回波原始频谱');
plotDoubleSidedSpectrum(signals.rx_antenna.x, signals.rx_antenna.t, ...
    'RX_Antenna 输出：接收回波原始频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '06_RX_Antenna输出_接收回波原始频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'Tap_Mixer_200MHz输出_上变频混频后宽频频谱');
plotDoubleSidedSpectrum(signals.tap_mixer_200mhz.x, signals.tap_mixer_200mhz.t, ...
    'Tap_Mixer_200MHz 输出：上变频混频后宽频频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '07_Tap_Mixer_200MHz输出_上变频混频后宽频频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'Tap_Up_BPF输出_上变频滤波后上边带频谱');
% plotDoubleSidedSpectrum(signals.tap_up_bpf.x, signals.tap_up_bpf.t, ...
%     'Tap_Up_BPF 输出：上变频滤波后上边带频谱', ...
%     normalizeSpectrumToPeak, useHannWindow);
plotAbsoluteDbSpectrum(signals.tap_up_bpf.x, signals.tap_up_bpf.t, ...
    'Tap_Up_BPF 输出：上变频滤波后上边带频谱', ...
     useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '08_Tap_Up_BPF输出_上变频滤波后上边带频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'RX_Down_Mixer输出_下变频混频后宽频频谱');
plotDoubleSidedSpectrum(signals.rx_down_mixer.x, signals.rx_down_mixer.t, ...
    'RX_Down_Mixer 输出：下变频混频后宽频频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '09_RX_Down_Mixer输出_下变频混频后宽频频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'RX_Down_IF_BPF输出_rx_down_if_log1中频频谱');
plotDoubleSidedSpectrum(signals.rx_down_if.x, signals.rx_down_if.t, ...
    'RX_Down_IF_BPF 输出：rx\_down\_if\_log1 中频频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '10_RX_Down_IF_BPF输出_rx_down_if_log1中频频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'IQ混频输出_LPF前双边复频谱');
plotDoubleSidedSpectrum(signals.iq_mixer.x, signals.iq_mixer.t, ...
    'IQ 混频输出（LPF 前）：双边复频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '11_IQ混频输出_LPF前双边复频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'IQ混频LPF后复基带_rx_iq_baseband_log1频谱');
plotDoubleSidedSpectrum(signals.iq_filtered.x, signals.iq_filtered.t, ...
    'IQ 混频 LPF 后复基带（rx\_iq\_baseband\_log1）：双边复频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '12_IQ混频LPF后复基带_rx_iq_baseband_log1频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'IQ基带输出_双边复频谱');
plotDoubleSidedSpectrum(signals.iq_baseband.x, signals.iq_baseband.t, ...
    'IQ 基带输出：双边复频谱', ...
    normalizeSpectrumToPeak, useHannWindow);
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '13_IQ基带输出_双边复频谱.png'); %#ok<SAGROW>

fig = figure('Color', 'w', 'Name', 'IFFT前后_复频响幅频相频曲线');
plotIfftBeforeAfter(signals.ifft_input.x, signals.ifft_output.x, ...
    'IFFT 前后：复频响幅频/相频曲线');
savedFiles{end + 1} = saveNamedFigure(fig, resultDir, ...
    '14_IFFT前后_复频响幅频相频曲线.png'); %#ok<SAGROW>

for i = 1:numel(savedFiles)
    fprintf('[保存] %s\n', savedFiles{i});
end

if showFiguresAfterSave
    bringGeneratedFiguresToFront();
end

cleanupBaseProbeVars({attached.varName});

fprintf('\n=== 完成 ===\n');
fprintf('本次脚本只修改并仿真临时模型，原始模型不会被保存或改线。\n');
fprintf('已生成图片数量：%d\n', numel(savedFiles));

%% ========================= 局部函数 =========================

function modelFile = autoFindModelFile(folderPath)
% 在当前目录自动寻找模型文件。
% 选择顺序：
%   1. 优先选择明确的 ex18.slx/ex18.mdl；
%   2. 如果当前已经打开了某个 Simulink 模型，优先使用这个打开的模型；
%   3. 如果只有一个模型文件，直接使用它；
%   4. 如果有多个模型文件，逐个只读加载并按关键节点打分，选择最像主电路的模型。
    preferred = {fullfile(folderPath, 'ex18.slx'), fullfile(folderPath, 'ex18.mdl')};
    for i = 1:numel(preferred)
        if isfile(preferred{i})
            modelFile = preferred{i};
            return;
        end
    end

    slxFiles = dir(fullfile(folderPath, '*.slx'));
    mdlFiles = dir(fullfile(folderPath, '*.mdl'));
    allFiles = [slxFiles; mdlFiles];

    % 忽略临时模型文件，避免上一次异常退出留下的临时副本干扰判断。
    keep = true(size(allFiles));
    for i = 1:numel(allFiles)
        [~, candidateBase] = fileparts(allFiles(i).name);
        keep(i) = isempty(regexpi(candidateBase, 'spectrum_tmp|tmp|backup|bak', 'once'));
    end
    allFiles = allFiles(keep);

    if isempty(allFiles)
        error('当前目录没有找到 .slx 或 .mdl 模型文件。');
    elseif numel(allFiles) == 1
        modelFile = fullfile(folderPath, allFiles(1).name);
        return;
    end

    openedModelFile = getCurrentOpenedModelFile(folderPath);
    if ~isempty(openedModelFile)
        fprintf('检测到当前打开的模型，自动选择：%s\n', openedModelFile);
        modelFile = openedModelFile;
        return;
    end

    fprintf('当前目录找到多个模型文件，正在自动判断主模型：\n');
    scores = zeros(numel(allFiles), 1);
    for i = 1:numel(allFiles)
        candidate = fullfile(folderPath, allFiles(i).name);
        scores(i) = scoreCandidateModel(candidate);
        fprintf('  %-40s  score = %.1f\n', allFiles(i).name, scores(i));
    end

    [bestScore, bestIdx] = max(scores);
    if bestScore <= 0
        fprintf('\n没有识别出明显主模型。请把脚本开头改成类似：\n');
        fprintf('  modelFile = ''你的主模型.slx'';\n\n');
        error('多个模型文件无法自动判断。');
    end

    modelFile = fullfile(folderPath, allFiles(bestIdx).name);
    fprintf('自动选择主模型：%s\n', modelFile);
end

function openedModelFile = getCurrentOpenedModelFile(folderPath)
% 如果用户已经打开了一个模型窗口，则优先使用该模型。
% 这样最符合"我正在看/正在运行的这个电路"的使用习惯。
    openedModelFile = '';
    try
        currentRoot = bdroot(gcs);
        if ~isempty(currentRoot) && bdIsLoaded(currentRoot)
            fileName = get_param(currentRoot, 'FileName');
            if isfile(fileName) && strcmpi(fileparts(fileName), folderPath)
                openedModelFile = fileName;
                return;
            end
        end
    catch
    end

    try
        loaded = find_system('Type', 'block_diagram');
        for i = 1:numel(loaded)
            fileName = get_param(loaded{i}, 'FileName');
            if isfile(fileName) && strcmpi(fileparts(fileName), folderPath)
                openedModelFile = fileName;
                return;
            end
        end
    catch
    end
end

function score = scoreCandidateModel(candidateFile)
% 给候选模型打分。只加载和读取块名，不保存、不改线。
% 分数越高，说明该模型越可能是包含 SFW/IQ/IFFT 主链路的顶层电路。
    score = 0;
    [~, modelBase] = fileparts(candidateFile);

    nameRules = { ...
        'ex18', 20; ...
        'main|top|system', 8; ...
        'radar|sfw|burst|iq|ifft', 6; ...
        'test|library|lib|sub|backup|bak', -10};
    for i = 1:size(nameRules, 1)
        if ~isempty(regexpi(modelBase, nameRules{i, 1}, 'once'))
            score = score + nameRules{i, 2};
        end
    end

    wasLoaded = bdIsLoaded(modelBase);
    try
        load_system(candidateFile);
        allBlocks = find_system(modelBase, ...
            'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', ...
            'Type', 'Block');
        names = get_param(allBlocks, 'Name');
        if ischar(names)
            names = {names};
        end

        keyRules = { ...
            '^SFW_Burst_Src$', 50; ...
            'SFW.*Burst.*Src|Burst.*Src', 35; ...
            '^RF_Out$|RF[_ ]?Out', 20; ...
            '^TX_Radiator$|TX[_ ]?Radiator', 20; ...
            '^RX_Antenna$|RX[_ ]?Antenna', 20; ...
            '^Tap_Mixer_200MHz$|Tap.*Mixer.*200', 18; ...
            '^Tap_Up_BPF$|Tap.*Up.*BPF|Up.*BPF', 18; ...
            '^RX_Down_Mixer$|RX.*Down.*Mixer|Down.*Mixer', 18; ...
            'IQ.*Mixer|IQ.*Mix|Mixer|Mix', 15; ...
            'IQ.*Baseband|Baseband|LPF|Low.*Pass', 15; ...
            '^IFFT$|Inverse.*FFT', 25; ...
            'FFT', 8};

        for r = 1:size(keyRules, 1)
            for n = 1:numel(names)
                if ~isempty(regexpi(names{n}, keyRules{r, 1}, 'once'))
                    score = score + keyRules{r, 2};
                    break;
                end
            end
        end

        % 顶层块较多的模型通常比纯子系统/库文件更像主模型。
        topBlocks = find_system(modelBase, 'SearchDepth', 1, 'Type', 'Block');
        score = score + min(numel(topBlocks), 20) * 0.2;
    catch
        score = score - 100;
    end

    if ~wasLoaded && bdIsLoaded(modelBase)
        close_system(modelBase, 0);
    end
end

function trySetModelParam(modelName, paramName, paramValue)
% 某些参数在不同 MATLAB/Simulink 版本中可能不存在，因此用安全设置。
    try
        set_param(modelName, paramName, paramValue);
    catch
        % 参数不可用时不影响主要功能。
    end
end

% 智能识别节点
function blockPath = findBlockByName(modelName, patterns)
% 按给定关键词/正则表达式寻找块名。
% 返回第一个最可信的候选块路径。
    blockPath = '';
    allBlocks = find_system(modelName, ...
        'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', ...
        'Type', 'Block');

    names = get_param(allBlocks, 'Name');
    if ischar(names)
        names = {names};
    end

    for p = 1:numel(patterns)
        pat = patterns{p};

        exactHit = strcmpi(names, pat);
        if any(exactHit)
            blockPath = allBlocks{find(exactHit, 1, 'first')};
            return;
        end

        regHit = false(size(names));
        for i = 1:numel(names)
            regHit(i) = ~isempty(regexpi(names{i}, pat, 'once'));
        end
        if any(regHit)
            blockPath = allBlocks{find(regHit, 1, 'first')};
            return;
        end
    end
end

function printUsefulCandidates(modelName, probeName)
% 自动匹配失败时，打印一些可能有用的块名，方便用户回填 probeList。
    keywords = {'SFW', 'Burst', 'IQ', 'Mixer', 'Mix', 'Baseband', ...
        'LPF', 'Low', 'Pass', 'FFT', 'IFFT', 'Range', 'RF', ...
        'TX', 'Radiator', 'RX', 'Antenna', 'Tap', 'BPF', 'Down', 'Up'};
    allBlocks = find_system(modelName, ...
        'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', ...
        'Type', 'Block');
    names = get_param(allBlocks, 'Name');
    if ischar(names)
        names = {names};
    end

    hit = false(size(names));
    for k = 1:numel(keywords)
        for i = 1:numel(names)
            hit(i) = hit(i) || ~isempty(regexpi(names{i}, keywords{k}, 'once'));
        end
    end

    idx = find(hit);
    if isempty(idx)
        return;
    end

    fprintf('  可参考的候选块名（用于 %s）：\n', probeName);
    for i = 1:min(numel(idx), 30)
        fprintf('    %s\n', allBlocks{idx(i)});
    end
end

function attachToWorkspaceProbe(modelName, blockPath, portType, portIndex, varName)
% 在临时模型中给指定端口增加一个 To Workspace 探针。
% 这里的 add_block/add_line 只作用于临时模型，不会碰原始电路。
    parentSystem = get_param(blockPath, 'Parent');
    probeBlock = [parentSystem '/' varName];

    if bdIsLoaded(modelName) && ~isempty(find_system(parentSystem, ...
            'SearchDepth', 1, 'Name', varName))
        delete_block(probeBlock);
    end

    add_block('simulink/Sinks/To Workspace', probeBlock, ...
        'VariableName', varName, ...
        'SaveFormat', 'Timeseries', ...
        'MaxDataPoints', 'inf', ...
        'Position', [40 40 180 75]);

    ph = get_param(blockPath, 'PortHandles');

    switch lower(portType)
        case 'out'
            if numel(ph.Outport) < portIndex
                error('块 %s 没有第 %d 个输出端口。', blockPath, portIndex);
            end
            srcPort = ph.Outport(portIndex);

        case 'in'
            lh = get_param(blockPath, 'LineHandles');
            if numel(lh.Inport) < portIndex || lh.Inport(portIndex) < 0
                error('块 %s 的第 %d 个输入端口没有接入信号线。', blockPath, portIndex);
            end
            srcPort = get_param(lh.Inport(portIndex), 'SrcPortHandle');
            if srcPort < 0
                error('无法找到 %s 第 %d 个输入端口的信号源。', blockPath, portIndex);
            end

        otherwise
            error('portType 只能是 out 或 in。');
    end

    probePorts = get_param(probeBlock, 'PortHandles');
    add_line(parentSystem, srcPort, probePorts.Inport(1), 'autorouting', 'on');
end

function raw = getSimOutVariable(simOut, varName)
% 从 SimulationOutput 中安全读取 To Workspace 变量。
    raw = [];
    try
        raw = simOut.get(varName);
        return;
    catch
    end

    try
        if isprop(simOut, varName)
            raw = simOut.(varName);
            return;
        end
    catch
    end

    % 如果当前 Simulink 版本没有把 To Workspace 返回到 simOut，
    % 变量可能被写入 base workspace。这里用唯一变量名兜底读取。
    try
        if evalin('base', sprintf('exist(''%s'', ''var'')', varName))
            raw = evalin('base', varName);
        end
    catch
    end
end

function signals = collectProbeSignals(simOut, attached)
% 把所有探针变量统一读成 signals.xxx.x 和 signals.xxx.t。
% 如果某个变量为空，立即报错，避免最后少图。
    signals = struct();
    for i = 1:numel(attached)
        item = attached(i);
        raw = getSimOutVariable(simOut, item.varName);
        if isempty(raw)
            error('simOut/base workspace 中没有找到探针变量：%s（节点：%s）', ...
                item.varName, item.name);
        end

        [x, t] = signalToVector(raw);
        if isempty(x)
            error('探针 %s 读取到的数据为空。', item.name);
        end

        signals.(item.name) = struct('x', x, 't', t);
    end
end

function [x, t] = signalToVector(raw)
% 将 To Workspace 记录的数据统一转成一维复数向量 x 和时间向量 t。
% 支持 timeseries、Structure With Time、普通数值数组等常见格式。
    x = [];
    t = [];

    if isa(raw, 'timeseries')
        t = raw.Time(:);
        data = raw.Data;
    elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
        t = raw.time(:);
        data = raw.signals.values;
    elseif isnumeric(raw)
        data = raw;
    else
        try
            data = raw.Values.Data;
            t = raw.Values.Time(:);
        catch
            warning('暂不支持的数据格式：%s', class(raw));
            return;
        end
    end

    data = squeeze(data);

    % 如果数据是 [N x 2] 或 [2 x N] 的实数形式，按 I/Q 两路合成为复信号。
    if isreal(data) && isnumeric(data)
        if ismatrix(data) && size(data, 2) == 2 && size(data, 1) > 2
            data = data(:, 1) + 1j * data(:, 2);
        elseif ismatrix(data) && size(data, 1) == 2 && size(data, 2) > 2
            data = data(1, :) + 1j * data(2, :);
        end
    end

    % 帧信号常表现为二维矩阵。这里取最长维度作为观测向量：
    %   - 若每个时刻输出一个频率向量，通常取最后一帧；
    %   - 若本来就是一列时间序列，则直接取整列。
    if isvector(data)
        x = data(:);
    elseif ismatrix(data)
        if ~isempty(t) && size(data, 1) == numel(t)
            if size(data, 2) == 1
                x = data(:, 1);
            else
                x = data(end, :).';
                t = [];
            end
        elseif ~isempty(t) && size(data, 2) == numel(t)
            if size(data, 1) == 1
                x = data(1, :).';
            else
                x = data(:, end);
                t = [];
            end
        elseif size(data, 1) >= size(data, 2)
            x = data(:, 1);
        else
            x = data(1, :).';
        end
    else
        data = data(:);
        x = data(:);
    end

    x = x(:);
    bad = ~isfinite(real(x)) | ~isfinite(imag(x));
    x(bad) = [];

    if ~isempty(t) && numel(t) ~= numel(x)
        t = [];
    end
end

function plotLinearSpectrum(x, t, ttl, useWindow)
% 绘制双边线性幅度频谱，不做 dB 转换，也不归一化。
    [f, mag, fScale, fLabel] = computeLinearSpectrum(x, t, useWindow);

    plot(f / fScale, mag, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel);
    ylabel('线性幅度');
    title(ttl, 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function plotLinearSpectrumCompare(x1, t1, label1, x2, t2, label2, ttl, useWindow)
% 绘制两路信号的双边线性幅度频谱对比。
    [f1, mag1, fScale1, fLabel1] = computeLinearSpectrum(x1, t1, useWindow);
    [f2, mag2, fScale2, ~] = computeLinearSpectrum(x2, t2, useWindow);

    if abs(fScale1 - fScale2) > eps
        f2 = f2 / fScale2 * fScale1;
    end

    plot(f1 / fScale1, mag1, 'LineWidth', 1.1); hold on;
    plot(f2 / fScale1, mag2, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel1);
    ylabel('线性幅度');
    title(ttl, 'Interpreter', 'none');
    legend({label1, label2}, 'Location', 'best', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function [f, mag, fScale, fLabel] = computeLinearSpectrum(x, t, useWindow)
% 计算双边线性幅度频谱。
    x = x(:);

    finiteMask = isfinite(real(x)) & isfinite(imag(x));
    if any(finiteMask)
        x = x - mean(x(finiteMask));
    end

    n = numel(x);
    if n < 4
        error('有效采样点太少，无法计算频谱。');
    end

    if nargin < 2 || isempty(t)
        fs = 1;
        fScale = 1;
        fLabel = '归一化频率';
    else
        dt = median(diff(t));
        fs = 1 / dt;
        [fScale, fLabel] = chooseFreqScale(fs);
    end

    nfft = 2 ^ nextpow2(max(n, 1024));

    if useWindow
        w = localHannWindow(n);
        coherentGain = mean(w);
        xw = x .* w;
    else
        coherentGain = 1;
        xw = x;
    end

    X = fftshift(fft(xw, nfft)) / max(n * coherentGain, eps);
    f = (-nfft/2:nfft/2-1).' * fs / nfft;
    mag = abs(X);
end


function plotAbsoluteDbSpectrum(x, t, ttl, useWindow)
% 绘制双边非归一化 dB 幅度频谱。
    [f, magDb, fScale, fLabel] = computeAbsoluteDbSpectrum(x, t, useWindow);

    plot(f / fScale, magDb, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel);
    ylabel('非归一化幅度 / dB');
    title(ttl, 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function plotAbsoluteDbSpectrumCompare(x1, t1, label1, x2, t2, label2, ttl, useWindow)
% 绘制两路信号的双边非归一化 dB 幅度频谱对比。
    [f1, mag1, fScale1, fLabel1] = computeAbsoluteDbSpectrum(x1, t1, useWindow);
    [f2, mag2, fScale2, ~] = computeAbsoluteDbSpectrum(x2, t2, useWindow);

    if abs(fScale1 - fScale2) > eps
        f2 = f2 / fScale2 * fScale1;
    end

    plot(f1 / fScale1, mag1, 'LineWidth', 1.1); hold on;
    plot(f2 / fScale1, mag2, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel1);
    ylabel('非归一化幅度 / dB');
    title(ttl, 'Interpreter', 'none');
    legend({label1, label2}, 'Location', 'best', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function [f, magDb, fScale, fLabel] = computeAbsoluteDbSpectrum(x, t, useWindow)
% 计算双边非归一化 dB 幅度频谱。
    x = x(:);

    finiteMask = isfinite(real(x)) & isfinite(imag(x));
    if any(finiteMask)
        x = x - mean(x(finiteMask));
    end

    n = numel(x);
    if n < 4
        error('有效采样点太少，无法计算频谱。');
    end

    if nargin < 2 || isempty(t)
        fs = 1;
        fScale = 1;
        fLabel = '归一化频率';
    else
        dt = median(diff(t));
        fs = 1 / dt;
        [fScale, fLabel] = chooseFreqScale(fs);
    end

    nfft = 2 ^ nextpow2(max(n, 1024));

    if useWindow
        w = localHannWindow(n);
        coherentGain = mean(w);
        xw = x .* w;
    else
        coherentGain = 1;
        xw = x;
    end

    X = fftshift(fft(xw, nfft)) / max(n * coherentGain, eps);
    f = (-nfft/2:nfft/2-1).' * fs / nfft;

    % 关键：这里是非归一化 dB，不减 max(magDb)
    magDb = 20 * log10(abs(X) + eps);
end


function plotDoubleSidedSpectrum(x, t, ttl, normalizeToPeak, useWindow)
% 绘制双边频谱。复信号会自然显示正、负频率两侧。
    [f, magDb, fScale, fLabel, yLabel] = computeDoubleSidedSpectrum( ...
        x, t, normalizeToPeak, useWindow);

    plot(f / fScale, magDb, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel);
    ylabel(yLabel);
    title(ttl, 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function [f, magDb, fScale, fLabel, yLabel] = computeDoubleSidedSpectrum(x, t, normalizeToPeak, useWindow)
% 计算双边频谱。单图和对比图共用该函数，保证频率轴和归一化方式一致。
    x = x(:);
    finiteMask = isfinite(real(x)) & isfinite(imag(x));
    if any(finiteMask)
        x = x - mean(x(finiteMask));
    end
    n = numel(x);

    if n < 4
        error('有效采样点太少，无法计算频谱。');
    end

    if nargin < 2 || isempty(t)
        fs = 1;
        fLabel = '归一化频率';
        fScale = 1;
    else
        dt = median(diff(t));
        fs = 1 / dt;
        [fScale, fLabel] = chooseFreqScale(fs);
    end

    nfft = 2 ^ nextpow2(max(n, 1024));

    if useWindow
        w = localHannWindow(n);
        coherentGain = mean(w);
        xw = x .* w;
    else
        coherentGain = 1;
        xw = x;
    end

    X = fftshift(fft(xw, nfft)) / max(n * coherentGain, eps);
    f = (-nfft/2:nfft/2-1).' * fs / nfft;
    magDb = 20 * log10(abs(X) + eps);

    if normalizeToPeak
        magDb = magDb - max(magDb);
        yLabel = '归一化幅度 / dB';
    else
        yLabel = '幅度 / dB';
    end
end

function plotSpectrumCompare(x1, t1, label1, x2, t2, label2, ttl, normalizeToPeak, useWindow)
% 绘制两路信号的双边频谱对比。
    [f1, mag1, fScale1, fLabel1, yLabel1] = computeDoubleSidedSpectrum( ...
        x1, t1, normalizeToPeak, useWindow);
    [f2, mag2, fScale2, ~, ~] = computeDoubleSidedSpectrum( ...
        x2, t2, normalizeToPeak, useWindow);

    if abs(fScale1 - fScale2) > eps
        f2 = f2 / fScale2 * fScale1;
    end

    plot(f1 / fScale1, mag1, 'LineWidth', 1.1); hold on;
    plot(f2 / fScale1, mag2, 'LineWidth', 1.1);
    grid on;
    xlabel(fLabel1);
    ylabel(yLabel1);
    title(ttl, 'Interpreter', 'none');
    legend({label1, label2}, 'Location', 'best', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function plotTimeAndSpectrogram(x, t, ttl)
% 绘制 SFW_Burst_Src 的时域波形和时频图。
% 时频图使用脚本内置 STFT，避免依赖 spectrogram 函数。
    x = x(:);
    n = numel(x);
    if n < 8
        error('有效采样点太少，无法绘制时频图。');
    end

    if isempty(t)
        t = (0:n-1).';
        fs = 1;
        timeScale = 1;
        timeLabel = '采样点';
        freqScale = 1;
        freqLabel = '归一化频率';
    else
        t = t(:);
        dt = median(diff(t));
        fs = 1 / dt;
        [timeScale, timeUnit] = chooseTimeScale(t);
        t = t / timeScale;
        timeLabel = ['时间 / ' timeUnit];
        [freqScale, freqLabel] = chooseFreqScale(fs);
    end

    subplot(2, 1, 1);
    plot(t, real(x), 'LineWidth', 1.0); hold on;
    if ~isreal(x)
        plot(t, imag(x), 'LineWidth', 1.0);
        legend({'I/实部', 'Q/虚部'}, 'Location', 'best');
    end
    grid on;
    xlabel(timeLabel);
    ylabel('幅度');
    title(ttl, 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');

    winLen = min(max(64, 2 ^ floor(log2(n / 16))), 1024);
    winLen = min(winLen, n);
    hop = max(1, floor(winLen / 4));
    nfft = 2 ^ nextpow2(max(winLen, 256));
    [S, tf, ff] = localStft(x, fs, winLen, hop, nfft);
    Sdb = 20 * log10(abs(S) + eps);
    Sdb = Sdb - max(Sdb(:));

    subplot(2, 1, 2);
    imagesc(tf / timeScale + min(t), ff / freqScale, Sdb);
    axis xy;
    try
        colormap turbo;
    catch
        colormap parula;
    end
    colorbar;
    caxis([-80 0]);
    xlabel(timeLabel);
    ylabel(freqLabel);
    title('短时频谱 / dB', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');
end

function [S, tf, ff] = localStft(x, fs, winLen, hop, nfft)
% 简单 STFT：返回双边频率轴，便于观察步进频率随时间变化。
    x = x(:);
    w = localHannWindow(winLen);
    starts = 1:hop:(numel(x) - winLen + 1);
    if isempty(starts)
        starts = 1;
        winLen = numel(x);
        w = localHannWindow(winLen);
    end

    S = zeros(nfft, numel(starts));
    for k = 1:numel(starts)
        idx = starts(k):(starts(k) + winLen - 1);
        frame = x(idx) .* w;
        S(:, k) = fftshift(fft(frame, nfft));
    end
    ff = (-nfft/2:nfft/2-1).' * fs / nfft;
    tf = ((starts(:) - 1) + winLen / 2) / fs;
end

function plotIfftBeforeAfter(xBefore, xAfter, ttl)
% 将 IFFT 前输入序列和 IFFT 后输出序列放在同一张图中对比。
    xBefore = xBefore(:);
    xAfter = xAfter(:);
    beforeIdx = (0:numel(xBefore)-1).';
    afterIdx = (0:numel(xAfter)-1).';

    beforeMag = 20 * log10(abs(xBefore) / max(abs(xBefore) + eps) + eps);
    afterMag = 20 * log10(abs(xAfter) / max(abs(xAfter) + eps) + eps);
    beforePhase = unwrap(angle(xBefore));
    afterPhase = unwrap(angle(xAfter));

    subplot(2, 2, 1);
    plot(beforeIdx, beforeMag, 'LineWidth', 1.1);
    grid on;
    xlabel('频率采样点');
    ylabel('归一化幅值 / dB');
    title('IFFT 前：幅频曲线', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');

    subplot(2, 2, 2);
    plot(beforeIdx, beforePhase, 'LineWidth', 1.1);
    grid on;
    xlabel('频率采样点');
    ylabel('相位 / rad');
    title('IFFT 前：相频曲线', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');

    subplot(2, 2, 3);
    plot(afterIdx, afterMag, 'LineWidth', 1.1);
    grid on;
    xlabel('距离/时延采样点');
    ylabel('归一化幅值 / dB');
    title('IFFT 后：幅值曲线', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');

    subplot(2, 2, 4);
    plot(afterIdx, afterPhase, 'LineWidth', 1.1);
    grid on;
    xlabel('距离/时延采样点');
    ylabel('相位 / rad');
    title('IFFT 后：相位曲线', 'Interpreter', 'none');
    set(gca, 'FontName', 'Microsoft YaHei');

    localSgtitle(ttl);
end

function localSgtitle(ttl)
% 兼容没有 sgtitle 的旧版 MATLAB。
    try
        sgtitle(ttl, 'Interpreter', 'none', 'FontName', 'Microsoft YaHei');
    catch
        annotation('textbox', [0 0.96 1 0.04], ...
            'String', ttl, ...
            'EdgeColor', 'none', ...
            'HorizontalAlignment', 'center', ...
            'Interpreter', 'none', ...
            'FontName', 'Microsoft YaHei');
    end
end

function [scale, unitText] = chooseTimeScale(t)
% 根据时间量级自动选择时间单位。
    span = max(t) - min(t);
    if span < 1e-6
        scale = 1e-9;
        unitText = 'ns';
    elseif span < 1e-3
        scale = 1e-6;
        unitText = 'us';
    elseif span < 1
        scale = 1e-3;
        unitText = 'ms';
    else
        scale = 1;
        unitText = 's';
    end
end

function pngPath = saveNamedFigure(fig, resultDir, pngName)
% 按指定中文文件名保存图片。
    pngPath = fullfile(resultDir, pngName);
    saveFigureAsPng(fig, pngPath);
end

function [scale, labelText] = chooseFreqScale(fs)
% 根据采样率自动选择频率单位。
    if fs >= 1e9
        scale = 1e9;
        labelText = '频率 / GHz';
    elseif fs >= 1e6
        scale = 1e6;
        labelText = '频率 / MHz';
    elseif fs >= 1e3
        scale = 1e3;
        labelText = '频率 / kHz';
    else
        scale = 1;
        labelText = '频率 / Hz';
    end
end

function w = localHannWindow(n)
% 不依赖 Signal Processing Toolbox 的 Hann 窗。
    if n <= 1
        w = ones(n, 1);
    else
        w = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / n);
    end
end

function saveFigureAsPng(fig, pngPath)
% 优先使用 exportgraphics；旧版 MATLAB 则退回 print。
    try
        exportgraphics(fig, pngPath, 'Resolution', 200);
    catch
        set(fig, 'PaperPositionMode', 'auto');
        print(fig, pngPath, '-dpng', '-r200');
    end
end

function bringGeneratedFiguresToFront()
% 将本脚本生成的图窗依次显示到前台。
% 脚本开头已经 close all，因此这里找到的基本就是本次生成的 12 张图。
    figs = findall(0, 'Type', 'figure');
    if isempty(figs)
        return;
    end

    % 按 Figure 编号从小到大唤起，最后会停在第 12 张图。
    try
        [~, order] = sort([figs.Number], 'ascend');
        figs = figs(order);
    catch
    end

    for i = 1:numel(figs)
        try
            set(figs(i), 'Visible', 'on');
            figure(figs(i));
            drawnow;
        catch
        end
    end
end

function cleanupBaseProbeVars(varNames)
% 清理兜底写入 base workspace 的探针变量，避免留下杂项变量。
    for i = 1:numel(varNames)
        try
            evalin('base', sprintf('if exist(''%s'', ''var''), clear(''%s''); end', ...
                varNames{i}, varNames{i}));
        catch
        end
    end
end

function closeTempModel(modelName)
% 关闭临时模型，不保存。
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end

function cleanupTempModel(tempRoot)
% 删除临时目录。失败也不影响原始模型。
    if exist(tempRoot, 'dir')
        try
            rmdir(tempRoot, 's');
        catch
        end
    end
end
