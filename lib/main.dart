import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

/// Replace with your free Agora App ID from https://console.agora.io
/// (Includes 10,000 free voice minutes every month for your squad)
const String kAgoraAppId = '545448eb8a2f4ba0a7a4d38ec349d4c0';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const SquadVoiceApp());
}

class SquadVoiceApp extends StatelessWidget {
  const SquadVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SquadVoice FF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF6B00), // Free Fire tactical orange
          secondary: Color(0xFF00E676),
          surface: Color(0xFF161B22),
        ),
      ),
      home: const SquadRoomScreen(),
    );
  }
}

class SquadMember {
  final int uid;
  bool isMuted;
  bool isSpeaking;
  int volume; // 0 to 200%

  SquadMember({
    required this.uid,
    this.isMuted = false,
    this.isSpeaking = false,
    this.volume = 100,
  });
}

class SquadRoomScreen extends StatefulWidget {
  const SquadRoomScreen({super.key});

  @override
  State<SquadRoomScreen> createState() => _SquadRoomScreenState();
}

class _SquadRoomScreenState extends State<SquadRoomScreen>
    with WidgetsBindingObserver {
  final TextEditingController _roomCodeController = TextEditingController();
  static const MethodChannel _iosAudioChannel =
      MethodChannel('com.squadvoice.ff/audio_session');

  RtcEngine? _engine;
  bool _inRoom = false;
  bool _isJoining = false;
  bool _isMicMuted = false;
  bool _isSpeakerphone = true;
  bool _preserveGameAudioStereo = true;
  bool _enableNoiseCancellation = true;
  String _activeRoomCode = '';
  int _localUid = 0;
  bool _localSpeaking = false;
  String _statusMessage = 'Ready — Enter or generate a squad room code';

  final Map<int, SquadMember> _squadMembers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _localUid = Random().nextInt(899999) + 100000;
    _roomCodeController.text = _generateRoomCode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _leaveAndDisposeEngine();
    _roomCodeController.dispose();
    super.dispose();
  }

  /// Keeps iOS 16 AVAudioSession active and mixed with Free Fire when switching apps
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_inRoom &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.resumed)) {
      _applyGameAudioMixMode();
    }
  }

  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random();
    final suffix =
        List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
    return 'FF-$suffix';
  }

  Future<void> _applyGameAudioMixMode() async {
    try {
      await _iosAudioChannel.invokeMethod('configureGameAudioSession', {
        'preserveGameStereo': _preserveGameAudioStereo,
      });
    } catch (_) {
      // Ignored on Android or if native channel is not attached
    }

    if (_engine != null) {
      // AudioScenarioGameStreaming prevents iOS from lowering Free Fire volume
      await _engine!.setAudioScenario(
        _preserveGameAudioStereo
            ? AudioScenarioType.audioScenarioGameStreaming
            : AudioScenarioType.audioScenarioChatroom,
      );
    }
  }

  /// Configures AI Noise Suppression (AINS) + Acoustic Echo Cancellation (AEC)
  /// to filter out ceiling fans, screen taps, traffic, and speaker echo.
  Future<void> _applyNoiseCancellation() async {
    if (_engine == null) return;
    try {
      await _engine!.setAINSMode(
        enabled: _enableNoiseCancellation,
        mode: AudioAinsMode.ainsModeUltralowlatency,
      );
      await _engine!.setParameters(
        '{"che.audio.ans.enable": $_enableNoiseCancellation, '
        '"che.audio.aec.enable": true, '
        '"che.audio.agc.enable": true}',
      );
    } catch (_) {
      // Fallback if device DSP does not support AINS extension
    }
  }

  Future<void> _joinRoom() async {
    final code = _roomCodeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _statusMessage = 'Please enter a valid Room Code.');
      return;
    }

    setState(() {
      _isJoining = true;
      _statusMessage = 'Requesting microphone permission...';
    });

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      setState(() {
        _isJoining = false;
        _statusMessage = 'Microphone permission is required for voice chat.';
      });
      return;
    }

    try {
      final engine = createAgoraRtcEngine();
      await engine.initialize(const RtcEngineContext(
        appId: kAgoraAppId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            setState(() {
              _inRoom = true;
              _isJoining = false;
              _activeRoomCode = code;
              _statusMessage =
                  'Connected to $code — Background voice & noise filter active';
            });
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            setState(() {
              _squadMembers[remoteUid] = SquadMember(uid: remoteUid);
            });
          },
          onUserOffline: (RtcConnection connection, int remoteUid,
              UserOfflineReasonType reason) {
            setState(() {
              _squadMembers.remove(remoteUid);
            });
          },
          onUserMuteAudio:
              (RtcConnection connection, int remoteUid, bool muted) {
            setState(() {
              _squadMembers[remoteUid]?.isMuted = muted;
            });
          },
          onAudioVolumeIndication: (
            RtcConnection connection,
            List<AudioVolumeInfo> speakers,
            int speakerNumber,
            int totalVolume,
          ) {
            if (!mounted) return;
            setState(() {
              _localSpeaking = false;
              for (final member in _squadMembers.values) {
                member.isSpeaking = false;
              }
              for (final speaker in speakers) {
                final active = (speaker.volume ?? 0) > 15;
                if (speaker.uid == 0) {
                  _localSpeaking = active;
                } else if (speaker.uid != null &&
                    _squadMembers.containsKey(speaker.uid)) {
                  _squadMembers[speaker.uid]!.isSpeaking = active;
                }
              }
            });
          },
          onError: (ErrorCodeType err, String msg) {
            setState(() {
              _isJoining = false;
              _statusMessage = 'Voice error ($err): $msg';
            });
          },
        ),
      );

      await engine.enableAudio();
      await engine.setAudioProfile(
        profile: AudioProfileType.audioProfileMusicStandard,
        scenario: _preserveGameAudioStereo
            ? AudioScenarioType.audioScenarioGameStreaming
            : AudioScenarioType.audioScenarioChatroom,
      );

      // Keep iOS AVAudioSession mixed with Free Fire audio
      await engine.setParameters('{"che.audio.keep.audiosession": true}');
      _engine = engine;

      await _applyGameAudioMixMode();
      await _applyNoiseCancellation();

      await engine.enableAudioVolumeIndication(
        interval: 250,
        smooth: 3,
        reportVad: true,
      );

      await engine.joinChannel(
        token: '', // Uses App ID testing mode or token server if configured
        channelId: code,
        uid: _localUid,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
        ),
      );
    } catch (e) {
      setState(() {
        _isJoining = false;
        _statusMessage = 'Failed to start room: $e';
      });
    }
  }

  Future<void> _leaveAndDisposeEngine() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      await engine.leaveChannel();
      await engine.release();
    }
    if (mounted) {
      setState(() {
        _inRoom = false;
        _squadMembers.clear();
        _activeRoomCode = '';
        _statusMessage = 'Disconnected from room';
      });
    }
  }

  Future<void> _toggleMic() async {
    if (_engine == null) return;
    final nextMute = !_isMicMuted;
    await _engine!.muteLocalAudioStream(nextMute);
    setState(() => _isMicMuted = nextMute);
  }

  Future<void> _toggleSpeakerphone() async {
    if (_engine == null) return;
    final nextSpeaker = !_isSpeakerphone;
    await _engine!.setEnableSpeakerphone(nextSpeaker);
    setState(() => _isSpeakerphone = nextSpeaker);
  }

  Future<void> _setMemberVolume(int uid, double value) async {
    if (_engine == null) return;
    final vol = value.round();
    await _engine!.adjustUserPlaybackSignalVolume(uid: uid, volume: vol);
    setState(() {
      _squadMembers[uid]?.volume = vol;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.headset_mic_rounded, color: Color(0xFFFF6B00)),
            SizedBox(width: 10),
            Text(
              'SQUADVOICE FF',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          if (_inRoom)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                backgroundColor: const Color(0x2E00E676),
                label: Text(
                  'LIVE: $_activeRoomCode',
                  style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRoomCodeCard(),
              const SizedBox(height: 12),
              _buildAudioEnhancementsCard(),
              const SizedBox(height: 12),
              Expanded(child: _buildSquadList()),
              if (_inRoom) _buildBottomVoiceControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoomCodeCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SQUAD ROOM CODE',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _roomCodeController,
                  enabled: !_inRoom && !_isJoining,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                  ),
                  decoration: InputDecoration(
                    hintText: 'FF-8492',
                    filled: true,
                    fillColor: const Color(0xFF0D1117),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Copy Code',
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: _roomCodeController.text.trim()),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Room code copied!')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, color: Colors.white70),
              ),
              if (!_inRoom)
                IconButton(
                  tooltip: 'New Random Code',
                  onPressed: () {
                    setState(() {
                      _roomCodeController.text = _generateRoomCode();
                    });
                  },
                  icon:
                      const Icon(Icons.refresh_rounded, color: Colors.white70),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _inRoom ? Colors.redAccent : const Color(0xFFFF6B00),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _isJoining
                  ? null
                  : (_inRoom ? _leaveAndDisposeEngine : _joinRoom),
              icon: Icon(_inRoom ? Icons.call_end_rounded : Icons.login_rounded),
              label: Text(
                _isJoining
                    ? 'CONNECTING...'
                    : (_inRoom ? 'LEAVE SQUAD ROOM' : 'JOIN / START VOICE ROOM'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _statusMessage,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioEnhancementsCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeThumbColor: const Color(0xFF00E676),
            title: const Text(
              'Free Fire Stereo & Full Game Volume',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            subtitle: const Text(
              'Prevents iOS 16 from lowering gunshot/footstep audio',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
            value: _preserveGameAudioStereo,
            onChanged: (val) {
              setState(() => _preserveGameAudioStereo = val);
              _applyGameAudioMixMode();
            },
          ),
          const Divider(color: Colors.white10, height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeThumbColor: const Color(0xFF00E676),
            title: const Text(
              'AI Noise Cancellation & Echo Filter',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            subtitle: const Text(
              'Blocks ceiling fans, finger taps, traffic & game speaker echo',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
            value: _enableNoiseCancellation,
            onChanged: (val) {
              setState(() => _enableNoiseCancellation = val);
              _applyNoiseCancellation();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSquadList() {
    final members = _squadMembers.values.toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SQUAD MEMBERS (${_inRoom ? members.length + 1 : 0}/4)',
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          if (!_inRoom)
            const Expanded(
              child: Center(
                child: Text(
                  'Share a Room Code with your squad and tap Join.\nThen switch straight to Free Fire!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, height: 1.5),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  _buildLocalMemberTile(),
                  ...members.map(_buildRemoteMemberTile),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalMemberTile() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: CircleAvatar(
        backgroundColor:
            _localSpeaking ? const Color(0xFF00E676) : Colors.white12,
        child: const Icon(Icons.person, color: Colors.white),
      ),
      title: Text(
        'You (#$_localUid)',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        _isMicMuted ? 'Mic Muted' : (_localSpeaking ? 'Speaking...' : 'Online'),
        style: TextStyle(
          color: _localSpeaking ? const Color(0xFF00E676) : Colors.white54,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildRemoteMemberTile(SquadMember member) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor:
                member.isSpeaking ? const Color(0xFF00E676) : Colors.white12,
            child: const Icon(Icons.sports_esports, color: Colors.white),
          ),
          title: Text(
            'Squadmate #${member.uid}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Row(
            children: [
              const Icon(Icons.volume_up, size: 16, color: Colors.white54),
              Expanded(
                child: Slider(
                  value: member.volume.toDouble(),
                  min: 0,
                  max: 200,
                  divisions: 20,
                  label: '${member.volume}%',
                  onChanged: (val) => _setMemberVolume(member.uid, val),
                ),
              ),
              Text(
                '${member.volume}%',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          trailing: Icon(
            member.isMuted ? Icons.mic_off : Icons.mic,
            color: member.isMuted ? Colors.redAccent : const Color(0xFF00E676),
          ),
        ),
        const Divider(color: Colors.white10),
      ],
    );
  }

  Widget _buildBottomVoiceControls() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _isMicMuted ? Colors.redAccent : const Color(0xFF21262D),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _toggleMic,
              icon: Icon(_isMicMuted ? Icons.mic_off : Icons.mic),
              label: Text(_isMicMuted ? 'UNMUTE MIC' : 'MUTE MIC'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF21262D),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _toggleSpeakerphone,
              icon: Icon(
                  _isSpeakerphone ? Icons.volume_up : Icons.hearing_rounded),
              label: Text(_isSpeakerphone ? 'SPEAKER ON' : 'EARPIECE / BT'),
            ),
          ),
        ],
      ),
    );
  }
}
