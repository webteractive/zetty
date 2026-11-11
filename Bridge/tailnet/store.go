package main

import (
	"encoding/json"
	"sync"

	"tailscale.com/ipn"
)

// blobStore keeps the node's state in memory and hands the whole map to
// persist on every change, so the app can keep it in the Keychain. The node
// key never touches a file. With persist nil (an ephemeral test node) it is
// memory only.
type blobStore struct {
	mu      sync.Mutex
	state   map[ipn.StateKey][]byte
	persist func([]byte)
}

func newBlobStore(initial []byte, persist func([]byte)) (*blobStore, error) {
	s := &blobStore{state: map[ipn.StateKey][]byte{}, persist: persist}
	if len(initial) > 0 {
		if err := json.Unmarshal(initial, &s.state); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *blobStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	bs, ok := s.state[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return append([]byte(nil), bs...), nil
}

func (s *blobStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	if bs == nil {
		delete(s.state, id)
	} else {
		s.state[id] = append([]byte(nil), bs...)
	}
	// Persisted under the lock, so saves reach the Keychain in the order
	// they were made (the callback only copies and queues).
	if s.persist != nil {
		// json encodes []byte as base64.
		if encoded, err := json.Marshal(s.state); err == nil {
			s.persist(encoded)
		}
	}
	s.mu.Unlock()
	return nil
}
