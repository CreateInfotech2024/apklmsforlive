import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'socket_service.dart';

class WebRTCService {
  static final WebRTCService _instance = WebRTCService._internal();
  factory WebRTCService() => _instance;
  WebRTCService._internal();

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  MediaStream? _localStream;
  bool _isAudioEnabled = true;
  bool _isVideoEnabled = true;
  String? _currentParticipantId;
  
  final SocketService _socketService = SocketService();
  
  // Callbacks
  Function(MediaStream, String)? onRemoteStreamAdded;
  Function(String)? onRemoteStreamRemoved;
  
  // Set current participant ID
  void setCurrentParticipantId(String participantId) {
    _currentParticipantId = participantId;
    _socketService.setCurrentParticipantId(participantId);
  }

  // Configuration for STUN servers with better connectivity
  final Map<String, dynamic> _configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // Media constraints with better compatibility
  final Map<String, dynamic> _mediaConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': {
      'facingMode': 'user',
      'width': {'min': 320, 'ideal': 640, 'max': 1280},
      'height': {'min': 240, 'ideal': 480, 'max': 720},
      'frameRate': {'ideal': 30, 'max': 30},
    }
  };

  // Initialize local media (camera and microphone)
  Future<MediaStream?> initializeLocalMedia() async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);
      _localStream = stream;
      print('✅ Local media initialized');
      return stream;
    } catch (e) {
      print('❌ Failed to initialize local media: $e');
      rethrow;
    }
  }

  // Get local stream
  MediaStream? getLocalStream() {
    return _localStream;
  }

  // Get remote streams
  Map<String, MediaStream> getRemoteStreams() {
    return _remoteStreams;
  }

  // Setup WebRTC signaling listeners
  void setupSignaling() {
    _socketService.onOffer((data) async {
      await _handleOffer(data);
    });

    _socketService.onAnswer((data) async {
      await _handleAnswer(data);
    });

    _socketService.onIceCandidate((data) async {
      await _handleIceCandidate(data);
    });
  }

  // Create peer connection for a participant
  Future<RTCPeerConnection> _createPeerConnection(String participantId) async {
    final peerConnection = await createPeerConnection(_configuration);

    // Handle incoming stream
    peerConnection.onTrack = (event) {
      print('📺 Received remote stream from $participantId');
      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        _remoteStreams[participantId] = stream;
        onRemoteStreamAdded?.call(stream, participantId);
      }
    };

    // Handle ICE candidates
    peerConnection.onIceCandidate = (candidate) {
      if (candidate != null) {
        _socketService.sendIceCandidate(
          {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
          participantId,
        );
      }
    };

    // Handle connection state changes
    peerConnection.onConnectionState = (state) {
      print('🔗 Connection state with $participantId: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        print('✅ Successfully connected to $participantId');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        print('❌ Connection failed with $participantId, attempting to reconnect...');
        // Try to reconnect after a delay
        Future.delayed(const Duration(seconds: 2), () {
          createOffer(participantId);
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        print('⚠️ Disconnected from $participantId');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        removeParticipant(participantId);
      }
    };
    
    // Handle ICE connection state changes
    peerConnection.onIceConnectionState = (state) {
      print('🧊 ICE connection state with $participantId: $state');
    };

    // Add local stream to peer connection
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        peerConnection.addTrack(track, _localStream!);
      });
    }

    _peerConnections[participantId] = peerConnection;
    return peerConnection;
  }

  // Handle incoming offer
  Future<void> _handleOffer(Map<String, dynamic> data) async {
    try {
      final offer = data['offer'];
      final from = data['from'];
      
      print('📥 Received offer from $from');
      
      // Skip if it's from ourselves
      if (from == _currentParticipantId) {
        print('⏭️ Skipping offer from self');
        return;
      }
      
      // Close existing connection if any
      if (_peerConnections.containsKey(from)) {
        print('♻️ Closing existing connection with $from');
        await _peerConnections[from]?.close();
        _peerConnections.remove(from);
      }
      
      final peerConnection = await _createPeerConnection(from);
      
      await peerConnection.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );
      
      // Create answer with proper constraints
      final answerConstraints = {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': true,
        },
      };
      
      final answer = await peerConnection.createAnswer(answerConstraints);
      await peerConnection.setLocalDescription(answer);
      
      _socketService.sendAnswer(
        {
          'sdp': answer.sdp,
          'type': answer.type,
        },
        from,
      );
      
      print('✅ Sent answer to $from');
    } catch (e) {
      print('❌ Error handling offer: $e');
    }
  }

  // Handle incoming answer
  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    try {
      final answer = data['answer'];
      final from = data['from'];
      
      print('📥 Received answer from $from');
      
      // Skip if it's from ourselves
      if (from == _currentParticipantId) {
        print('⏭️ Skipping answer from self');
        return;
      }
      
      final peerConnection = _peerConnections[from];
      if (peerConnection != null) {
        await peerConnection.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
        print('✅ Set remote description from answer: $from');
      } else {
        print('⚠️ No peer connection found for $from');
      }
    } catch (e) {
      print('❌ Error handling answer: $e');
    }
  }

  // Handle incoming ICE candidate
  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    try {
      final candidateData = data['candidate'];
      final from = data['from'];
      
      // Skip if it's from ourselves
      if (from == _currentParticipantId) {
        return;
      }
      
      final peerConnection = _peerConnections[from];
      if (peerConnection != null) {
        final candidate = RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        );
        await peerConnection.addCandidate(candidate);
        print('🧊 Added ICE candidate from $from');
      } else {
        print('⚠️ No peer connection found for ICE candidate from $from');
      }
    } catch (e) {
      print('❌ Error handling ICE candidate: $e');
    }
  }

  // Create offer for a new participant
  Future<void> createOffer(String participantId) async {
    try {
      // Skip if trying to create offer to self
      if (participantId == _currentParticipantId) {
        print('⏭️ Skipping offer to self');
        return;
      }
      
      print('📤 Creating offer for $participantId');
      
      // Close existing connection if any
      if (_peerConnections.containsKey(participantId)) {
        print('♻️ Closing existing connection with $participantId');
        await _peerConnections[participantId]?.close();
        _peerConnections.remove(participantId);
      }
      
      final peerConnection = await _createPeerConnection(participantId);
      
      // Create offer with proper constraints
      final offerConstraints = {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': true,
        },
      };
      
      final offer = await peerConnection.createOffer(offerConstraints);
      await peerConnection.setLocalDescription(offer);
      
      _socketService.sendOffer(
        {
          'sdp': offer.sdp,
          'type': offer.type,
        },
        participantId,
      );
      
      print('✅ Offer created and sent to $participantId');
    } catch (e) {
      print('❌ Error creating offer: $e');
    }
  }

  // Toggle audio
  void toggleAudio() {
    if (_localStream != null) {
      final audioTracks = _localStream!.getAudioTracks();
      for (var track in audioTracks) {
        track.enabled = !track.enabled;
      }
      _isAudioEnabled = !_isAudioEnabled;
      _socketService.toggleAudio(_isAudioEnabled);
    }
  }

  // Toggle video
  void toggleVideo() {
    if (_localStream != null) {
      final videoTracks = _localStream!.getVideoTracks();
      for (var track in videoTracks) {
        track.enabled = !track.enabled;
      }
      _isVideoEnabled = !_isVideoEnabled;
      _socketService.toggleVideo(_isVideoEnabled);
    }
  }

  // Get media states
  Map<String, bool> getMediaStates() {
    return {
      'audio': _isAudioEnabled,
      'video': _isVideoEnabled,
    };
  }

  // Remove participant
  void removeParticipant(String participantId) {
    final peerConnection = _peerConnections[participantId];
    if (peerConnection != null) {
      peerConnection.close();
      _peerConnections.remove(participantId);
    }
    
    final stream = _remoteStreams[participantId];
    if (stream != null) {
      stream.dispose();
      _remoteStreams.remove(participantId);
      onRemoteStreamRemoved?.call(participantId);
    }
  }

  // Clean up all resources
  Future<void> cleanup() async {
    // Stop local stream
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        track.stop();
      });
      await _localStream!.dispose();
      _localStream = null;
    }

    // Close all peer connections
    for (var peerConnection in _peerConnections.values) {
      await peerConnection.close();
    }
    _peerConnections.clear();

    // Dispose remote streams
    for (var stream in _remoteStreams.values) {
      await stream.dispose();
    }
    _remoteStreams.clear();
  }
}
