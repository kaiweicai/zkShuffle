import { useEffect, useState } from 'react';

function useShuffledListener(
  contract: any,
  creator: string,
  joiner: string,
  address: string
) {
  const [isCreatorShuffled, setIsCreatorShuffled] = useState(false);
  const [isJoinerShuffled, setIsJoinerShuffled] = useState(false);
  const [isShouldTriggerJoinerShuffle, setIsShouldTriggerJoinerShuffle] =
    useState(false);

  const isCreator = creator === address;

  const reset = () => {
    setIsCreatorShuffled(false);
    setIsJoinerShuffled(false);
    setIsShouldTriggerJoinerShuffle(false);
  };
  // game ShuffleListener
  useEffect(() => {
    if (!contract) return;
    const GameShuffledListener = async (arg1: string, shuffledAddress: any) => {
      try {
        const gameId = Number(arg1);

        console.log('shuffledAddress', shuffledAddress);
        if (shuffledAddress === creator) {
          setIsCreatorShuffled(true);
        }

        if (shuffledAddress === joiner) {
          setIsJoinerShuffled(true);
        }

        if (shuffledAddress === creator) {
          //  joiner goes to shuffle
          if (!isCreator) {
            setIsShouldTriggerJoinerShuffle(true);
          }
        }
      } catch (error) {
        console.log('GameShuffledListener error');
      }
    };

    contract?.on('ShuffleDeck', GameShuffledListener);
    return () => {
      contract?.off('ShuffleDeck', GameShuffledListener);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contract, isCreator, creator, joiner]);

  const shuffleStatus = {
    creator: isCreatorShuffled,
    joiner: isJoinerShuffled,
    isShouldTriggerJoinerShuffle: isShouldTriggerJoinerShuffle,
  };

  return {
    shuffleStatus,
    reset,
  };
}

export default useShuffledListener;
