import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { httpClient } from '../../../shared/api';

export const useUserStatus = (customId, { delay = 100 } = {}) => {
  const {
    data: user,
    refetch,
    isFetching,
    isLoading,
  } = useQuery({
    queryKey: ['users', 'userStatus', customId],
    queryFn: () => httpClient.get(`/users/${customId}`),
    enabled: !!customId,
    refetchOnWindowFocus: true,
    retry: false,
  });

  useEffect(() => {
    if (!customId) return;

    const timer = setTimeout(() => {
      refetch();
    }, delay);

    return () => clearTimeout(timer);
  }, [customId, delay, refetch]);

  return {
    userOnline: user?.status.isOnline,
    isFetching,
    isLoading,
    refetch,
  };
};
