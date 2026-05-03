"""
Unit Tests for TinyLLM Matmul Accelerator

Test vectors and golden models for validating DSP MAC units and
accumulation pipeline on the Zynq FPGA platform.

Author: TinyLLM FPGA Team
Date: May 2026
"""

import numpy as np
from typing import Tuple, List
import sys

class MatmulGoldenModel:
    """Software reference model for matmul operations."""
    
    @staticmethod
    def mac_unit(weights: np.ndarray, activations: np.ndarray, 
                 clear_on_start: bool = True) -> np.int64:
        """
        Simulate a single 8x8 MAC unit over a vector pair.
        
        Args:
            weights: 1D array of int8 values
            activations: 1D array of int8 values
            clear_on_start: If True, initialize accumulator to 0
            
        Returns:
            int64 accumulated result
        """
        assert len(weights) == len(activations), \
            f"Length mismatch: {len(weights)} vs {len(activations)}"
        assert weights.dtype == np.int8, f"Expected int8, got {weights.dtype}"
        assert activations.dtype == np.int8, f"Expected int8, got {activations.dtype}"
        
        acc = np.int64(0) if clear_on_start else np.int64(0)
        for w, a in zip(weights, activations):
            acc += np.int64(w) * np.int64(a)
        return acc
    
    @staticmethod
    def parallel_mac_16lane(weights_128: np.ndarray, activations_128: np.ndarray) -> np.int64:
        """
        Simulate 16 parallel MAC lanes processing 128-bit vectors.
        
        Args:
            weights_128: int8 array of exactly 16 elements
            activations_128: int8 array of exactly 16 elements
            
        Returns:
            int64 result (sum of all 16 MAC outputs)
        """
        assert len(weights_128) == 16, f"Expected 16 weights, got {len(weights_128)}"
        assert len(activations_128) == 16, f"Expected 16 activations, got {len(activations_128)}"
        
        result = np.int64(0)
        for i in range(16):
            result += np.int64(weights_128[i]) * np.int64(activations_128[i])
        return result
    
    @staticmethod
    def matmul_vector(weights: np.ndarray, activations: np.ndarray) -> np.ndarray:
        """
        Compute matrix-vector product: output[j] = sum_i(weights[j,i] * activations[i])
        
        Args:
            weights: (output_dim, input_dim) int8 array
            activations: (input_dim,) int8 array
            
        Returns:
            (output_dim,) int32 array of neuron outputs
        """
        output_dim, input_dim = weights.shape
        assert len(activations) == input_dim, \
            f"Activation size {len(activations)} != input_dim {input_dim}"
        
        output = np.zeros(output_dim, dtype=np.int32)
        for j in range(output_dim):
            output[j] = np.sum(weights[j, :].astype(np.int64) * 
                              activations[:].astype(np.int64))
        return output


class TestVectors:
    """Collection of predefined test vectors."""
    
    @staticmethod
    def simple_unit_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """
        Simplest test: 16 bytes, weights all 1s, activations 0..15.
        Expected result: 0+1+2+...+15 = 120 = 0x78
        """
        weights = np.ones(16, dtype=np.int8)
        activations = np.arange(16, dtype=np.int8)
        expected = np.int64(120)
        return weights, activations, expected
    
    @staticmethod
    def zeros_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Test with all zeros. Expected: 0"""
        weights = np.zeros(16, dtype=np.int8)
        activations = np.arange(16, dtype=np.int8)
        expected = np.int64(0)
        return weights, activations, expected
    
    @staticmethod
    def alternating_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Alternating 1/-1 pattern."""
        weights = np.array([1 if i % 2 == 0 else -1 for i in range(16)], dtype=np.int8)
        activations = np.ones(16, dtype=np.int8)
        expected = np.int64(0)  # 1-1+1-1+... = 0
        return weights, activations, expected
    
    @staticmethod
    def max_positive_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Maximum positive test: 127 * 127 * 16 (saturated to int64)"""
        weights = np.full(16, 127, dtype=np.int8)
        activations = np.full(16, 127, dtype=np.int8)
        expected = np.int64(127 * 127 * 16)
        return weights, activations, expected
    
    @staticmethod
    def max_negative_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Maximum negative test: (-128) * (-128) * 16"""
        weights = np.full(16, -128, dtype=np.int8)
        activations = np.full(16, -128, dtype=np.int8)
        expected = np.int64(128 * 128 * 16)
        return weights, activations, expected
    
    @staticmethod
    def mixed_sign_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Mixed positive/negative values."""
        weights = np.array([-5, -3, -1, 0, 1, 3, 5, 7, -2, -4, -6, -8, 2, 4, 6, 8], dtype=np.int8)
        activations = np.array([10, 8, 6, 4, 2, 0, -2, -4, -6, -8, -10, 1, 3, 5, 7, 9], dtype=np.int8)
        # Manual calculation:
        # -5*10 + -3*8 + -1*6 + 0*4 + 1*2 + 3*0 + 5*-2 + 7*-4 + -2*-6 + -4*-8 + -6*-10 + -8*1 + 2*3 + 4*5 + 6*7 + 8*9
        # = -50 - 24 - 6 + 0 + 2 + 0 - 10 - 28 + 12 + 32 + 60 - 8 + 6 + 20 + 42 + 72
        expected = np.int64(MatmulGoldenModel.mac_unit(weights, activations))
        return weights, activations, expected
    
    @staticmethod
    def sparse_pattern_test() -> Tuple[np.ndarray, np.ndarray, np.int64]:
        """Sparse pattern: weights all 0 except at indices 0, 3, 7, 15."""
        weights = np.zeros(16, dtype=np.int8)
        weights[[0, 3, 7, 15]] = [5, -3, 10, 2]
        activations = np.arange(16, dtype=np.int8)
        # 5*0 + -3*3 + 10*7 + 2*15 = 0 - 9 + 70 + 30 = 91
        expected = np.int64(91)
        return weights, activations, expected


class TestRunner:
    """Runs test suite and reports results."""
    
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.tests = []
    
    def run_test(self, name: str, weights: np.ndarray, activations: np.ndarray, 
                 expected: np.int64) -> bool:
        """
        Run a single test and validate result.
        
        Args:
            name: Test name
            weights: 16-element int8 array
            activations: 16-element int8 array
            expected: Expected int64 result
            
        Returns:
            True if test passed, False otherwise
        """
        result = MatmulGoldenModel.parallel_mac_16lane(weights, activations)
        passed = (result == expected)
        
        status = "PASS" if passed else "FAIL"
        print(f"[{status}] {name}")
        exp_val = int(expected) & 0xFFFFFFFFFFFFFFFF
        res_val = int(result) & 0xFFFFFFFFFFFFFFFF
        print(f"      Expected: {expected} (0x{exp_val:016X})")
        print(f"      Got:      {result} (0x{res_val:016X})")
        
        if not passed:
            print(f"      Mismatch: {result - expected}")
        
        self.tests.append((name, passed))
        if passed:
            self.passed += 1
        else:
            self.failed += 1
        
        return passed
    
    def run_all(self):
        """Execute full test suite."""
        print("=" * 70)
        print("TinyLLM Matmul Unit Test Suite")
        print("=" * 70)
        print()
        
        # Test 1: Simple unit test
        w, a, e = TestVectors.simple_unit_test()
        self.run_test("Simple Unit Test (weights=1, activations=0..15)", w, a, e)
        print()
        
        # Test 2: All zeros
        w, a, e = TestVectors.zeros_test()
        self.run_test("All Zeros Test", w, a, e)
        print()
        
        # Test 3: Alternating pattern
        w, a, e = TestVectors.alternating_test()
        self.run_test("Alternating 1/-1 Pattern", w, a, e)
        print()
        
        # Test 4: Max positive
        w, a, e = TestVectors.max_positive_test()
        self.run_test("Maximum Positive (127*127*16)", w, a, e)
        print()
        
        # Test 5: Max negative
        w, a, e = TestVectors.max_negative_test()
        self.run_test("Maximum Negative (-128*-128*16)", w, a, e)
        print()
        
        # Test 6: Mixed signs
        w, a, e = TestVectors.mixed_sign_test()
        self.run_test("Mixed Sign Values", w, a, e)
        print()
        
        # Test 7: Sparse pattern
        w, a, e = TestVectors.sparse_pattern_test()
        self.run_test("Sparse Weight Pattern", w, a, e)
        print()
        
        # Summary
        print("=" * 70)
        print(f"Test Summary: {self.passed} passed, {self.failed} failed")
        print("=" * 70)
        
        return self.failed == 0


class MatvecTestVectors:
    """Test vectors for matrix-vector multiplication."""
    
    @staticmethod
    def simple_2x4_test() -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Simple 2x4 matrix-vector product."""
        weights = np.array([[1, 2, 3, 4],
                           [5, 6, 7, 8]], dtype=np.int8)
        activations = np.array([1, 2, 3, 4], dtype=np.int8)
        # output[0] = 1*1 + 2*2 + 3*3 + 4*4 = 1 + 4 + 9 + 16 = 30
        # output[1] = 5*1 + 6*2 + 7*3 + 8*4 = 5 + 12 + 21 + 32 = 70
        expected = np.array([30, 70], dtype=np.int32)
        return weights, activations, expected
    
    @staticmethod
    def identity_test() -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Identity matrix (should return activations)."""
        size = 8
        weights = np.eye(size, dtype=np.int8)
        activations = np.arange(1, size + 1, dtype=np.int8)
        expected = activations.astype(np.int32)
        return weights, activations, expected


class MatvecTestRunner:
    """Runs matrix-vector tests."""
    
    def __init__(self):
        self.passed = 0
        self.failed = 0
    
    def run_test(self, name: str, weights: np.ndarray, activations: np.ndarray,
                 expected: np.ndarray) -> bool:
        """Run a matrix-vector test."""
        result = MatmulGoldenModel.matmul_vector(weights, activations)
        passed = np.allclose(result, expected)
        
        status = "PASS" if passed else "FAIL"
        print(f"[{status}] {name}")
        print(f"      Shape: {weights.shape}")
        
        if not passed:
            print(f"      Expected: {expected}")
            print(f"      Got:      {result}")
            print(f"      Max diff: {np.max(np.abs(result - expected))}")
        
        if passed:
            self.passed += 1
        else:
            self.failed += 1
        
        return passed
    
    def run_all(self):
        """Execute matrix-vector test suite."""
        print("=" * 70)
        print("Matrix-Vector Multiplication Test Suite")
        print("=" * 70)
        print()
        
        # Test 1: Simple 2x4
        w, a, e = MatvecTestVectors.simple_2x4_test()
        self.run_test("Simple 2x4 Matrix-Vector", w, a, e)
        print()
        
        # Test 2: Identity
        w, a, e = MatvecTestVectors.identity_test()
        self.run_test("Identity Matrix", w, a, e)
        print()
        
        print("=" * 70)
        print(f"Matvec Summary: {self.passed} passed, {self.failed} failed")
        print("=" * 70)
        
        return self.failed == 0


def main():
    """Main test runner."""
    # Run MAC unit tests
    mac_runner = TestRunner()
    mac_passed = mac_runner.run_all()
    print()
    
    # Run matrix-vector tests
    matvec_runner = MatvecTestRunner()
    matvec_passed = matvec_runner.run_all()
    print()
    
    # Overall summary
    total_passed = mac_runner.passed + matvec_runner.passed
    total_failed = mac_runner.failed + matvec_runner.failed
    
    print("=" * 70)
    print(f"OVERALL RESULTS: {total_passed} passed, {total_failed} failed")
    print("=" * 70)
    
    sys.exit(0 if total_failed == 0 else 1)


if __name__ == "__main__":
    main()
