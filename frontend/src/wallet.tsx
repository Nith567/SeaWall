import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Address } from "viem";

import { ANVIL_CHAIN_ID_HEX, RPC_URL, hasInjectedWallet } from "./config";

type WalletState = {
  address: Address | null;
  available: boolean;
  connecting: boolean;
  error: string | null;
  connect: () => Promise<void>;
  disconnect: () => void;
};

const WalletContext = createContext<WalletState>({
  address: null,
  available: false,
  connecting: false,
  error: null,
  connect: async () => {},
  disconnect: () => {},
});

type Eip1193 = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: never[]) => void) => void;
  removeListener?: (event: string, handler: (...args: never[]) => void) => void;
};

const ethereum = (): Eip1193 | undefined =>
  typeof window === "undefined" ? undefined : (window as unknown as { ethereum?: Eip1193 }).ethereum;

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<Address | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    const eth = ethereum();
    if (!eth) {
      setError("No injected wallet found. Install MetaMask or use the demo keys.");
      return;
    }
    setConnecting(true);
    setError(null);
    try {
      const accounts = (await eth.request({ method: "eth_requestAccounts" })) as string[];
      try {
        await eth.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: ANVIL_CHAIN_ID_HEX }],
        });
      } catch (switchError) {
        const code = (switchError as { code?: number }).code;
        if (code === 4902) {
          await eth.request({
            method: "wallet_addEthereumChain",
            params: [
              {
                chainId: ANVIL_CHAIN_ID_HEX,
                chainName: "Anvil (Seawall demo)",
                nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
                rpcUrls: [RPC_URL],
              },
            ],
          });
        } else {
          throw switchError;
        }
      }
      setAddress(accounts[0] as Address);
    } catch (e) {
      setError((e as Error).message ?? "Wallet connection failed");
    } finally {
      setConnecting(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    setAddress(null);
    setError(null);
  }, []);

  useEffect(() => {
    const eth = ethereum();
    if (!eth?.on) return;
    const onAccountsChanged = (...args: never[]) => {
      const accounts = args[0] as unknown as string[];
      setAddress(accounts.length > 0 ? (accounts[0] as Address) : null);
    };
    eth.on("accountsChanged", onAccountsChanged);
    return () => eth.removeListener?.("accountsChanged", onAccountsChanged);
  }, []);

  const value = useMemo<WalletState>(
    () => ({ address, available: hasInjectedWallet(), connecting, error, connect, disconnect }),
    [address, connecting, error, connect, disconnect],
  );

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function useWallet(): WalletState {
  return useContext(WalletContext);
}
