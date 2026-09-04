package spire

import (
	"errors"
	"fmt"
)

// Typed errors for different failure modes
var (
	ErrSPIREConnection = errors.New("SPIRE server connection failed")
	ErrSPIREOperation  = errors.New("SPIRE operation failed")
	ErrInvalidEntry    = errors.New("invalid SPIRE entry")
)

type MultipleEntriesError struct {
	SPIFFEID string
	Count    int
}

func (e MultipleEntriesError) Error() string {
	return fmt.Sprintf("multiple SPIRE entries found for SPIFFE ID %s: %d entries", e.SPIFFEID, e.Count)
}

func NewMultipleEntriesError(spiffeID string, count int) *MultipleEntriesError {
	return &MultipleEntriesError{
		SPIFFEID: spiffeID,
		Count:    count,
	}
}

type SPIREConnectionError struct {
	Addr string
	Err  error
}

func (e SPIREConnectionError) Error() string {
	return fmt.Sprintf("failed to connect to SPIRE server at %s: %v", e.Addr, e.Err)
}

func (e SPIREConnectionError) Unwrap() error {
	return e.Err
}

type SPIREOperationError struct {
	Operation string
	Err       error
}

func (e SPIREOperationError) Error() string {
	return fmt.Sprintf("SPIRE %s operation failed: %v", e.Operation, e.Err)
}

func (e SPIREOperationError) Unwrap() error {
	return e.Err
}

// Legacy function for backward compatibility
func ErrMultipleEntries(spiffeID string) error {
	return NewMultipleEntriesError(spiffeID, 0)
}
