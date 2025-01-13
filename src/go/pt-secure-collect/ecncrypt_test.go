package main

import (
	"os"
	"testing"

	"github.com/AlekSi/pointer"
	"github.com/stretchr/testify/require"
)

func TestEncrypt(t *testing.T) {
	data := []byte("The quick brown fox jumps over the lazy dog")

	input, err := os.CreateTemp(".", "*-input")
	require.NoError(t, err)
	t.Cleanup(func() { os.Remove(input.Name()) })

	err = os.WriteFile(input.Name(), data, 0o600)
	require.NoError(t, err)

	output, err := os.CreateTemp(".", "*-output")
	require.NoError(t, err)
	t.Cleanup(func() { os.Remove(output.Name()) })

	encrypted, err := os.CreateTemp(".", "*-encrypted")
	require.NoError(t, err)
	t.Cleanup(func() { os.Remove(encrypted.Name()) })

	err = encryptorCmd(&cliOptions{
		Command:         "encrypt",
		EncryptPassword: pointer.ToString("password"),
		EncryptInFile:   pointer.ToString(input.Name()),
		EncryptOutFile:  pointer.ToString(encrypted.Name()),
	})
	require.NoError(t, err)

	encryptedData, err := os.ReadFile(encrypted.Name())
	require.NoError(t, err)

	// Check that the encrypted data is different from the original data
	require.NotEqual(t, data, encryptedData)

	err = encryptorCmd(&cliOptions{
		Command:         "decrypt",
		EncryptPassword: pointer.ToString("password"),
		DecryptInFile:   pointer.ToString(encrypted.Name()),
		DecryptOutFile:  pointer.ToString(output.Name()),
	})
	require.NoError(t, err)

	decryptedData, err := os.ReadFile(output.Name())
	require.NoError(t, err)

	// Check that the decrypted data is the same as the original data
	require.Equal(t, data, decryptedData)
}
