import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/app_widgets.dart';
import '../../services/asr/model_manager.dart';

/// 模型下载/就绪页：首启引导下载本地 ASR 模型，显示进度。
class ModelSetupScreen extends ConsumerStatefulWidget {
  const ModelSetupScreen({super.key});

  @override
  ConsumerState<ModelSetupScreen> createState() => _ModelSetupScreenState();
}

class _ModelSetupScreenState extends ConsumerState<ModelSetupScreen> {
  double _progress = 0;
  String _status = '准备中…';
  bool _downloading = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final mmAsync = ref.watch(modelManagerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: mmAsync.when(
          data: (mm) => _build(mm, theme),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败：$e')),
        ),
      ),
    );
  }

  Widget _build(ModelManager mm, ThemeData theme) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final systemEngine = settings?.engine == 'system';
    final language = settings?.engine == 'cloud'
        ? 'auto'
        : settings?.recognitionLanguage ?? 'zh';
    final requiredLanguages = systemEngine
        ? const <String>[]
        : ModelManager.languagesRequiredFor(language);
    final ready = requiredLanguages.every(mm.isReady);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.xl),
          Container(
            width: 88,
            height: 88,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ready
                  ? AppColors.green.withValues(alpha: 0.14)
                  : AppColors.tint.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              ready ? Icons.offline_pin_rounded : Icons.download_rounded,
              size: 40,
              color: ready ? AppColors.green : AppColors.tint,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            systemEngine
                ? '系统增强识别已就绪'
                : ready
                    ? '离线识别模型已就绪'
                    : '准备本地语音识别模型',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            ready
                ? systemEngine
                    ? '将使用 Android 系统语音识别服务，不需要安装本地模型。'
                    : '当前语种模型已就绪，可离线运行。切换语种时会按需准备。'
                : '首次只准备当前识别语种，切换语种时再按需加载。'
                    '\n首次安装需要联网，也可到“存储与资源”从文件安装。安装完成后仍可离线听写，识别效果不变。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium!
                .copyWith(color: AppColors.secondaryLabel),
          ),
          const Spacer(),
          if (_downloading || _failed)
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 8,
                    backgroundColor: AppColors.fill(theme.brightness),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(_status, style: theme.textTheme.bodySmall),
              ],
            ),
          const SizedBox(height: AppSpacing.lg),
          PillButton(
            label: ready ? '开始使用' : (_downloading ? '安装中…' : '下载安装模型'),
            expanded: true,
            height: 52,
            onPressed: _downloading
                ? null
                : ready
                    ? () => Navigator.of(context).pop(true)
                    : () => _download(mm, language),
          ),
        ],
      ),
    );
  }

  Future<void> _download(ModelManager mm, String language) async {
    setState(() {
      _downloading = true;
      _failed = false;
    });
    try {
      await mm.prepare(
        language: language,
        onProgress: (p, msg) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _status = msg;
          });
        },
      );
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = error.message ?? '准备未完成，请检查网络与存储空间后重试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '准备未完成，请检查网络与存储空间后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }
}
