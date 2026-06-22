# ex18 SFW RF Front-End Demo

`ex18` 是步进频率波形（SFW, stepped-frequency waveform）和 RF Blockset 前端观察工程。信号源仍由 MATLAB timeseries 生成，耦合器、衰减器、可调放大器和功率放大器使用 RF Blockset 器件/网络。当前版本已经加入由 ex08 土壤模型转换得到的 GPR 时域 FIR 通道、接收天线、耦合支路 200 MHz 上变频和接收端下变频链路。

## Run

```matlab
cd('D:/work place/Matlab/ex18')
setup_ex18_sfw
sim('ex18_sfw_top')
```

离线画各观测点的时域局部图和频谱图，不修改 `.slx`：

```matlab
ex18_plot_scope_spectra
```

快速两频点仿真后直接分析：

```matlab
ex18_plot_scope_spectra('RunSimulation', true, 'StepCount', 2)
```

如果只是检查仪器显示和频率搬移，可降低预览采样率以加快仿真：

```matlab
ex18_plot_scope_spectra('RunSimulation', true, 'StepCount', 2, 'SampleRate', 2e9)
```

单位置 A-scan 后处理，不修改 `.slx`：

```matlab
ex18_make_ascan
```

从当前单位置 Simulink 模型跑完整 501 频点并生成 A-scan。当前 ex18 默认采样率为 1 GHz，足够覆盖 370 MHz 上变频支路，适合先验证算法：

```matlab
ex18_make_ascan('RunSimulation', true, 'SampleRate', 1e9)
```

如果后续把 `cfg.time.fs_hz` 改回更高采样率，运行和日志体积会明显增加。A-scan 输出默认保存到 `output/ex18_ascan.png` 和 `output/ex18_ascan.mat`。

ICZT A-scan（在指定时延窗口内高分辨率成像）：

```matlab
% 使用模型参考数据：
ex18_make_ascan_iczt

% 自动围绕理论目标时延缩放：
ex18_make_ascan_iczt('AutoZoom', true)

% 指定时延范围 (ns) 和分辨率：
ex18_make_ascan_iczt('DelayStartNs', 0, 'DelayStopNs', 80, 'NumDelayPoints', 8192)

% 仿真 + ICZT：
ex18_make_ascan_iczt('RunSimulation', true, 'SampleRate', 1e9)
```

ICZT 相比 IFFT 的优势：可在任意时延区间 [t_start, t_stop] 内以任意步长 dt 计算 A-scan，无需对整个不模糊距离范围逐点 IFFT。输出默认保存到 `output/ex18_ascan_iczt_*.png` 和 `.mat`。需 MATLAB Signal Processing Toolbox（`czt` 函数）。

已记录点包括 `sfw_src_ts`、`rf_out_log`、`rx_antenna_log`、`tap_up_log` 和 `rx_down_if_log`。`Scope_RF_Main_Out` 是实时 Scope 观察点，若需要离线分析可额外打开 Scope data logging 或增加 `To Workspace` 分支。

重新生成模型：

```matlab
cd('D:/work place/Matlab/ex18')
build_ex18_sfw_top
open_system('ex18_sfw_top')
```

## Model Blocks

```text
SFW_Burst_Src
    ├-> Spec_Src / Scope_SFW_Source
    ↓
RF_In -> RF_Coupler -> RF_Attn -> RF_VGA -> RF_PA -> RF_Out -> Scope_RF_Main_Out
             │                                        └-> TX_Radiator -> Scope_TX_Radiated / Log_RF
             │                                                      └-> GPR_Channel -> RX_Antenna ┐
             │                                                                                 ↓
             ├-> RF_Tap_Out -> Tap_Mixer_200MHz -> Tap_Up_BPF ─┬-> Scope_Tap_Upconverted / Log_Tap
             │                                                  └-> RX_Down_Mixer -> RX_Down_IF_BPF ─┬-> Scope_RX_Down_IF / Log_RX
             │                                                                                         └-> IQ_Complex_Mixer -> IQ_LPF_Complex ─┬-> Scope_RX_IQ_Baseband
             │                                                                                                                                    └-> Log_RX_IQ
             │                                                                 IQ_LO_cos -┬-> IQ_LO_Complex ─┘
             │                                                                 IQ_LO_nsin ─┘
             └-> Iso_Term -> Gnd
```

命名约定：

| 名称 | 含义 |
|---|---|
| `SFW_Burst_Src` | PDF 方法生成的步进频率 burst 源 |
| `Spec_Src` / `Scope_SFW_Source` | 源信号频谱和时域观察器 |
| `RF_In` | Simulink 信号到 RF Blockset 网络的输入端口 |
| `RF_Coupler` | RF Blockset 四端口 S 参数耦合器，端口 2 为主路直通，端口 4 为耦合支路 |
| `RF_Attn` | RF Blockset 衰减器，位于耦合器主路输出之后 |
| `RF_VGA` | RF Blockset 放大器，用作可调放大器，位于主路衰减器之后 |
| `RF_PA` | RF Blockset 放大器，用作功率放大器，位于可调放大器之后 |
| `RF_Out` | 主路 RF 输出端口，将 RF Blockset 信号转为 Simulink 信号 |
| `TX_Radiator` | 主路发射天线，当前为 Phased Array 的各向同性辐射器 |
| `Radiation_Angle` | 发射方向，当前为 `[0;0]`，即方位角/俯仰角均为 0 度 |
| `GPR_Channel` | ex08 土壤模型 FIR 通道，包含直耦、地表反射、弱杂波和管道目标 |
| `RX_Antenna` | 接收天线，当前为 Phased Array 的各向同性接收器 |
| `RX_Angle` | 接收方向，当前为 `[0;0]` |
| `Tap_LO_200MHz` | 200 MHz 本振，输出 `tap_lo_amp*cos(2*pi*tap_lo_hz*t)` |
| `Tap_Mixer_200MHz` | 耦合支路实数混频器，将 `RF_Tap_Out` 与 200 MHz 本振相乘 |
| `Tap_Up_BPF` | 支路上变频带通滤波器，保留 `200 MHz + f_tap` 上边带 |
| `RX_Down_Mixer` | 下变频混频器，将支路上变频信号与 `RX_Antenna` 输出相乘 |
| `RX_Down_IF_BPF` | 下变频 IF 带通滤波器，保留约 200 MHz 差频分量 |
| `IQ_Complex_Mixer` | 复数乘法混频器，将复数 IF 信号与复数本振 `exp(-jwt)` 相乘，直接下变频到基带 |
| `IQ_LO_cos` | 复数本振实部：`cos(2*pi*iq_lo_hz*t)`，振幅为 1 |
| `IQ_LO_nsin` | 复数本振虚部：`-sin(2*pi*iq_lo_hz*t)`，振幅为 1 |
| `IQ_LO_Complex` | Real-Imag to Complex 合成复数本振 `exp(-j*2*pi*iq_lo_hz*t) = cos(wt) - j*sin(wt)` |
| `IQ_LPF_Complex` | 复数基带 10 MHz 低通（Discrete FIR Filter），滤除 400 MHz 和频分量 |
| `RF_Tap_Out` | 耦合支路 RF 输出端口 |
| `Iso_Term` / `Gnd` | 耦合器隔离端 50 欧端接 |
| `Scope_RF_Main_Out` | RF Blockset 主路输出端口后的时域观察器 |
| `Scope_TX_Radiated` | 发射天线输出时域观察器 |
| `Scope_Tap_Upconverted` | 耦合支路上变频带通输出时域观察器 |
| `Scope_RX_Down_IF` | 接收端下变频 IF 输出时域观察器 |
| `Scope_RX_IQ_Baseband` | I/Q 解调后复数基带时域观察器 |
| `Log_RF` / `Log_Tap` / `Log_RX` / `Log_RX_IQ` | 发射天线输出、支路上变频输出、下变频 IF 输出和 IQ 基带日志 |

## Main Files

| 文件 | 作用 |
|---|---|
| `ex18_sfw_top.slx` | 当前顶层 Simulink 模型 |
| `build_ex18_sfw_top.m` | 从零生成顶层模型 |
| `setup_ex18_sfw.m` | 参数中心，生成 base workspace 变量 |
| `make_sfw_burst.m` | PDF 步进频率 burst 波形生成函数 |
| `ex18_make_ascan.m` | 从单位置仿真日志或模型频响提取复频响并生成 A-scan |
| `ex18_make_ascan_iczt.m` | 使用 ICZT（Inverse Chirp Z-Transform）在指定时延窗口内高分辨率生成 A-scan |
| `ex18_make_bscan.m` | 多位置 A-scan 合成 B-scan 图像 |
| `ex18_plot_scope_spectra.m` | 离线画 Scope 对应信号的时域局部图和频谱图 |
| `ex18_save_model_diagram_and_connections.m` | 保存模型图和连线清单 |

### 子目录

| 目录 | 内容 |
|---|---|
| `filterlib/` | FIR 带通/低通滤波器设计 (`ex18_design_fir_bandpass.m`, `ex18_design_fir_lowpass.m`) 和土壤 FIR 转换 (`ex18_make_ex08_soil_fir.m`) |
| `dialogs/` | 模块双击回调：放大器增益编辑 (`ex18_amp_dialog.m`) 和滤波器参数编辑 (`ex18_filter_dialog.m`) |
| `patches/` | 历史一次性修复脚本（已归档，不再使用） |

## Key Variables

`setup_ex18_sfw.m` 会写入这些主要变量：

| 变量 | 含义 |
|---|---|
| `sfw_src_ts` | From Workspace 读取的时域源 timeseries |
| `sfw_freq_ts` | 每个 step 对应频率的 timeseries，单位 MHz |
| `sfw_freq_hz` | 频率计划，单位 Hz |
| `sfw_df_hz` | 频率步进 |
| `sfw_fs_hz` | 采样率 |
| `sfw_sample_s` | 固定步长 |
| `sfw_pri_s` | 每个频点的 PRI |
| `sfw_pulse_s` | 每个频点的脉宽 |
| `sfw_duty` | 占空比 |
| `sfw_stop_s` | 仿真停止时间 |
| `sfw_range_res_m` | 距离分辨率，`c/(2*n*df)` |
| `sfw_unamb_range_m` | 不模糊距离，`c/(2*df)` |
| `rf_z0_ohm` | RF 网络参考阻抗 |
| `rf_attn_db` | RF 衰减器衰减量 |
| `rf_vga_s` / `rf_vga_gain_db` / `rf_vga_nf_db` | 可调放大器的 2 端口 S 参数、增益和噪声系数 |
| `rf_pa_s` / `rf_pa_gain_db` / `rf_pa_nf_db` | 功率放大器的 2 端口 S 参数、增益和噪声系数 |
| `rf_cpl_db` | 耦合度 |
| `rf_cpl_directivity_db` | 耦合器方向性 |
| `rf_cpl_insertion_loss_db` | 耦合器直通端插入损耗 |
| `rf_cpl_return_loss_db` | 耦合器端口回波损耗 |
| `rf_cpl_s` | RF_Coupler 使用的四端口 S 参数矩阵 |
| `rf_cpl_freq_hz` | 耦合器参数参考频率 |
| `gpr_soil_eps_r` | 简化 GPR 通道使用的土壤相对介电常数，来自 ex08 |
| `gpr_soil_sigma_s_per_m` | 土壤电导率，单位 S/m，来自 ex08 |
| `gpr_soil_fir` | GPR_Channel 使用的 ex08 土壤模型 FIR 系数 |
| `gpr_soil_model` | FIR 生成时保存的频响、冲激响应和通道分量信息 |
| `gpr_channel_freq_hz` / `gpr_channel_response` | ex08 土壤模型在 FIR 频率网格上的频响 |
| `gpr_direct_delay_samples` | 直耦路径延迟样点数 |
| `gpr_surface_delay_samples` | 地表反射路径延迟样点数 |
| `gpr_target_delay_samples` | 目标回波路径延迟样点数 |
| `gpr_direct_gain` / `gpr_surface_gain` / `gpr_target_gain` | 三条通道路径的线性增益 |
| `tap_lo_hz` / `tap_lo_amp` | 耦合支路变频本振频率和幅度 |
| `tap_up_bpf_hz` | 支路上变频带通滤波器通带 |
| `tap_up_bpf_num` / `tap_up_bpf_den` | 支路上变频带通滤波器离散传递函数系数 |
| `rx_down_if_bpf_hz` | 下变频 IF 带通滤波器通带 |
| `rx_down_if_bpf_num` / `rx_down_if_bpf_den` | 下变频 IF 带通滤波器离散传递函数系数 |
| `iq_lo_hz` / `iq_lo_amp` | I/Q 正交解调本振频率和幅度 |
| `iq_lpf_cutoff_hz` / `iq_lpf_num` | I/Q 低通滤波器截止频率和 FIR 系数 |
默认配置在 `setup_ex18_sfw.m` 的 `default_cfg()` 中：

```matlab
cfg.freq.f0_hz = 20e6;
cfg.freq.df_hz = 0.3e6;
cfg.freq.n = 501;

cfg.time.pri_s = 1e-6;
cfg.time.pulse_s = cfg.time.pri_s;
cfg.time.fs_hz = 1e9;

cfg.src.amp = 1;
cfg.src.phase_rad = 0;
cfg.src.phase_continuous = true;

cfg.front.z0_ohm = 50;
cfg.front.attn_db = 10;
cfg.front.vga_gain_db = 0;
cfg.front.vga_nf_db = 4;
cfg.front.pa_gain_db = 10;
cfg.front.pa_nf_db = 5;
cfg.front.cpl_db = 6;
cfg.front.cpl_directivity_db = inf;
cfg.front.cpl_insertion_loss_db = 3;
cfg.front.cpl_return_loss_db = inf;

ex08 = sfcw_pipe_get_config('backend', 'simplified');
cfg.gpr.soil_eps_r = ex08.soil.eps_r;
cfg.gpr.soil_sigma_s_per_m = ex08.soil.sigma_s_per_m;
cfg.gpr.target_depth_m = ex08.pipe.center_z_m;
cfg.gpr.fir_len = [];
cfg.gpr.fir_guard_s = 10e-9;

cfg.tap_mixer.lo_hz = 200e6;
cfg.tap_mixer.lo_amp = 2;
cfg.tap_mixer.input_band_hz = [cfg.freq.f0_hz, cfg.freq.f1_hz];
cfg.tap_mixer.lower_sideband_hz = cfg.tap_mixer.lo_hz - fliplr(cfg.tap_mixer.input_band_hz);
cfg.tap_mixer.upper_sideband_hz = cfg.tap_mixer.lo_hz + cfg.tap_mixer.input_band_hz;
cfg.tap_mixer.up_bpf_guard_hz = 10e6;
cfg.tap_mixer.up_bpf_hz = cfg.tap_mixer.upper_sideband_hz + ...
    [-cfg.tap_mixer.up_bpf_guard_hz, cfg.tap_mixer.up_bpf_guard_hz];
cfg.tap_mixer.up_bpf_order = 8192;

cfg.down_mixer.if_center_hz = cfg.tap_mixer.lo_hz;
cfg.down_mixer.if_half_bw_hz = 10e6;
cfg.down_mixer.if_bpf_hz = cfg.down_mixer.if_center_hz + ...
    [-cfg.down_mixer.if_half_bw_hz, cfg.down_mixer.if_half_bw_hz];
cfg.down_mixer.if_bpf_order = 8192;

cfg.iq_demod.lo_hz = cfg.down_mixer.if_center_hz;
cfg.iq_demod.lo_amp = 2;
cfg.iq_demod.lpf_cutoff_hz = 10e6;
cfg.iq_demod.lpf_order = 1024;
```

当前默认 `pulse_s = pri_s`，所以 Scope 中频率之间没有水平零线。若要恢复 PDF 图示那种有静默间隔的脉冲串，将 `cfg.time.pulse_s` 改成小于 `cfg.time.pri_s` 的值。

当前信号源默认开启 `cfg.src.phase_continuous = true`。频率从一个 step 跳到下一个 step 时，RF 相位由相位累加器连续传递，因此波形幅值不会在频点边界出现垂直突跳。若要恢复按绝对时间直接计算 `cos(2*pi*f_i*t + theta_i)` 的非连续跳频效果，可运行 `setup_ex18_sfw('PhaseContinuous', false)`。

主路前端当前为 `RF_Coupler -> RF_Attn -> RF_VGA -> RF_PA -> RF_Out`。默认 `RF_VGA = 0 dB`、`RF_PA = 10 dB`，使 `VGA + PA` 总增益接近原来单个 10 dB 放大级；后续调主路增益时优先改 `cfg.front.vga_gain_db` 和 `cfg.front.pa_gain_db`。

`setup_ex18_sfw.m` 会直接读取 `ex08/sfcw_pipe_get_config.m` 的 simplified 配置。`GPR_Channel` 使用 `ex18_make_ex08_soil_fir.m` 复现 ex08 simplified 后端的均匀有损土壤、地表反射、弱杂波和管道目标频响，并转换成适合 ex18 时域链路的 FIR 滤波器。ex18 当前仍是单个固定扫描位置的时域前端模型，不是 ex08 那种完整 B-scan 频域处理链。

`cfg.gpr.fir_len = []` 表示 FIR 抽头数按当前采样率、目标/杂波最大延迟和 `cfg.gpr.fir_guard_s` 自动计算。当前 1 GHz 默认仿真下约为 64 taps，覆盖目标 13.5 ns 回波；如果改成 50 GHz，则会生成约 2048 taps。

`ex18_make_ascan.m` 默认从 `rx_antenna_log / sfw_src_ts` 按 501 个频点同步解调得到复频响；若没有仿真日志，则使用 `gpr_soil_model.sfcw_response` 生成模型参考 A-scan。脚本默认用 `gpr_soil_model.sfcw_parts.background_response` 做模型背景扣除，并补偿 ex08 前端名义群时延 `3.8 ns`，因此输出的目标峰应接近物理目标延迟。当前单位置预期目标延迟约 `13.54 ns`，等效深度约 `0.677 m`，管道中心深度为 `0.720 m`。

耦合支路先做上变频：`RF_Tap_Out -> Tap_Mixer_200MHz -> Tap_Up_BPF`。20-170 MHz 支路信号与 200 MHz 本振混频后，`Tap_Up_BPF` 以 210-380 MHz 通带保留 220-370 MHz 上边带，同时抑制 200 MHz - f 低边带。随后 `RX_Down_Mixer` 将该上变频支路信号与 `RX_Antenna` 输出相乘，`RX_Down_IF_BPF` 以 190-210 MHz 通带保留约 200 MHz 的差频项并抑制实数混频和频项。两个带通均为窗函数 FIR，避免高采样率、低归一化频率下 IIR 直接型滤波器数值发散。`Log_Tap` 记录支路上变频输出，`Log_RX` 记录下变频 IF 输出，`rx_antenna_log` 保存接收天线原始输出。

接收端最终级为复数 IQ 正交解调架构：RF Blockset 输出的复数 IF 信号（190-210 MHz）直接与复数本振 `exp(-j*2*pi*iq_lo_hz*t)` 相乘，一步完成下变频到基带。复数本振由 `IQ_LO_cos`（`cos(wt)`）和 `IQ_LO_nsin`（`-sin(wt)`）经 `IQ_LO_Complex`（Real-Imag to Complex）合成为 `cos(wt) - j*sin(wt)`。`IQ_Complex_Mixer`（Product）将复数 IF 与复数本振相乘后，`IQ_LPF_Complex`（10 MHz 截止 Discrete FIR Filter）滤除 400 MHz 和频分量，直接输出复数基带信号至 `Scope_RX_IQ_Baseband` 和 `Log_RX_IQ`。该架构完全保留复数 IF 的 I/Q 双通道信息，无实部截断损失。
